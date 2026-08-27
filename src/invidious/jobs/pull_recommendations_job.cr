#
# Builds a pool of personalized recommendations per user in the background.
#
# Doing this up front means a request to the "Popular" feed never has to talk to
# YouTube: it samples from the pool instead. Because the pool is much larger than
# a single page, reloading the feed keeps showing a different mix, which is what
# the old synchronous implementation spent up to 28 upstream requests on.
#
# Candidates are ranked rather than shuffled. The signals are all local and free:
# how many of the user's seeds recommended the same video, whether its channel is
# subscribed to or one the user actually watches, how fresh it is, and how it
# performed. See `rank` for the weights.
#
# Collection runs in two hops. The first takes the user's watch history and
# subscription feed as seeds. The second re-expands the best candidates from the
# first as seeds in their own right, which is what turns co-occurrence from a
# per-seed tally into a graph signal: it can reach the video several of the
# user's interests converge on, rather than only direct neighbours of what they
# already watched. Second-hop contributions are damped, since those videos were
# never actually watched.
#
# Note that the local `videos` table is only a six hour cache: ClearExpiredItems
# deletes anything older than that. So a daily rebuild has to fetch most of its
# seeds, which is what `recommendations_fetch_budget` bounds. Fetches are spaced
# out to avoid a burst of concurrent requests to YouTube.
#
class Invidious::Jobs::PullRecommendationsJob < Invidious::Jobs::BaseJob
  # Recommendation pools, keyed by user email, ranked best first.
  POOLS = Atomic.new({} of String => Array(SearchVideo))

  # Number of seed videos taken from the user's watch history, newest first.
  # Together with SUBSCRIPTION_SEEDS this should stay in step with the first
  # hop's share of `recommendations_fetch_budget` (see HOP2_BUDGET_SHARE):
  # seeds beyond the budget are never fetched, and budget beyond the seeds is
  # never spent.
  private HISTORY_SEEDS = 60
  # Number of seed videos taken from the user's subscription feed.
  private SUBSCRIPTION_SEEDS = 40
  # Upper bound on a single user's pool, to keep memory use predictable.
  private POOL_SIZE = 500
  # Pause between two fetches, so a rebuild trickles rather than bursts.
  private FETCH_SPACING = 1.second

  # Scoring weights. Co-occurrence dominates: a video that several of the seeds
  # recommend is far more likely to be relevant than one only a single seed did.
  private COOCCURRENCE_WEIGHT = 3.0
  # Bonus when the channel is one the user subscribes to.
  private SUBSCRIBED_BOOST = 2.0
  # Bonus when the channel is one the seeds came from, i.e. actually watched.
  private AFFINITY_BOOST = 1.0
  # Weight of freshness, which halves at RECENCY_HALFLIFE.
  private RECENCY_WEIGHT   =  1.5
  private RECENCY_HALFLIFE = 30.0
  # Weight of the view count, dampened logarithmically.
  private VIEWS_WEIGHT = 0.5
  # Multiplier applied to Shorts, which otherwise flood the pool.
  private SHORTS_PENALTY = 0.25
  private SHORTS_LENGTH  =   60
  # Maximum videos one channel may contribute, so a single channel can't take
  # over the feed.
  private MAX_PER_CHANNEL = 5

  # Number of top-ranked first-hop candidates re-expanded as second-hop seeds.
  private HOP2_SEEDS = 40
  # Weight multiplier for what a second-hop seed recommends. Kept well below
  # 1.0: these videos were never watched, so their neighbours are a weaker
  # signal, and undamped they would drag the pool towards generic popular
  # content, which is exactly what the sidebar is padded with.
  private HOP2_DAMPING = 0.4
  # Fraction of the fetch budget held back for the second hop, so a long watch
  # history can't spend all of it on first-hop seeds. The total spend per
  # rebuild is unchanged: this only decides how it is split.
  private HOP2_BUDGET_SHARE = 0.35

  # A candidate video plus the accumulated weight of the seeds that recommended
  # it. Scoring happens after every seed is in, in `rank`.
  private class Candidate
    property video : SearchVideo
    property cooccurrence : Float64

    def initialize(@video : SearchVideo)
      @cooccurrence = 0.0
    end
  end

  private getter db : DB::Database

  # Remaining number of videos that may be fetched from YouTube this rebuild.
  @budget : Int32 = 0
  # Level `@budget` may not be spent below, used to reserve the second hop's
  # share while the first hop is running.
  @budget_floor : Int32 = 0

  def initialize(@db)
  end

  # Returns the current pool for a user, or an empty array if it hasn't been
  # built yet (a cold start, since pools are not persisted across restarts).
  def self.pool_for(email : String) : Array(SearchVideo)
    POOLS.get[email]? || [] of SearchVideo
  end

  def begin
    # The pools live in memory only, so build once at startup rather than
    # leaving the feed empty until the next scheduled run.
    run_once

    loop do
      delay = time_until_next_run
      LOGGER.debug("PullRecommendationsJob: sleeping for #{delay}")
      sleep delay

      run_once
      Fiber.yield
    end
  end

  # Time until the next configured rebuild hour, in server local time.
  private def time_until_next_run : Time::Span
    now = Time.local

    hours = CONFIG.recommendations_refresh_hours.map(&.clamp(0, 23)).uniq.sort
    # Fall back to a single daily rebuild if the list was configured empty
    hours = [10] if hours.empty?

    midnight = now.at_beginning_of_day

    # The next hour still to come today, else the first one tomorrow
    next_run = hours.map { |hour| midnight + hour.hours }.find { |time| time > now }
    next_run ||= midnight + 1.day + hours.first.hours

    return next_run - now
  end

  private def run_once
    rebuild_all
  rescue ex
    LOGGER.error("PullRecommendationsJob: #{ex.message}")
  end

  private def rebuild_all
    @budget = CONFIG.recommendations_fetch_budget

    previous = POOLS.get
    pools = {} of String => Array(SearchVideo)

    db.query_all("SELECT email FROM users", as: String).each do |email|
      user = Invidious::Database::Users.select(email: email)
      next if user.nil?

      pool = build_pool(user)

      # Keep the last known good pool if this rebuild produced nothing, so a
      # transient failure doesn't empty out the feed.
      pool = previous[email]? || pool if pool.empty?
      pools[email] = pool unless pool.empty?

      LOGGER.info("PullRecommendationsJob: #{pool.size} videos pooled for #{email}")
    end

    POOLS.set(pools)
    LOGGER.info("PullRecommendationsJob: rebuilt #{pools.size} pool(s), #{@budget} fetch(es) of budget left")
  end

  private def build_pool(user : User) : Array(SearchVideo)
    watched = user.watched.to_set
    subscriptions = user.subscriptions.to_set

    candidates = {} of String => Candidate
    # Channels the seeds came from, which is a decent proxy for what the user
    # actually watches as opposed to what they once subscribed to.
    seed_authors = Set(String).new
    # Seeds already spent, so the second hop doesn't pay to fetch them again.
    seeded = Set(String).new

    # Hold the second hop's share back before the first hop starts spending.
    @budget_floor = (CONFIG.recommendations_fetch_budget * HOP2_BUDGET_SHARE).to_i

    seed_ids(user).each_with_index do |seed_id, index|
      begin
        seeded << seed_id

        video = fetch_seed(seed_id)
        next if video.nil?
        next unless video.video_type == VideoType::Video

        # Guard the empty case: `ucid` defaults to "", and an empty entry here
        # would hand the affinity boost to every channel-less candidate.
        seed_authors << video.ucid unless video.ucid.empty?
        collect(candidates, video, seed_weight(index), watched)
      rescue ex
        # One malformed video must not cost us the whole rebuild
        LOGGER.error("PullRecommendationsJob: seed #{seed_id} failed: #{ex.message}")
      end
    end

    hop1_candidates = candidates.size

    # Second hop. Ranking first means the expansion starts from the strongest
    # candidates and inherits the per-channel cap, so the second generation is
    # as diverse as the first rather than 40 videos from one channel.
    @budget_floor = 0

    hop2_seeds = rank(candidates, subscriptions, seed_authors)
      .reject { |video| seeded.includes?(video.id) }
      .first(HOP2_SEEDS)

    hop2_seeds.each_with_index do |seed, index|
      begin
        video = fetch_seed(seed.id)
        next if video.nil?
        next unless video.video_type == VideoType::Video

        # Deliberately not added to `seed_authors`: this video was never
        # watched, so its channel says nothing about the user's taste.
        collect(candidates, video, HOP2_DAMPING * seed_weight(index), watched)
      rescue ex
        LOGGER.error("PullRecommendationsJob: hop 2 seed #{seed.id} failed: #{ex.message}")
      end
    end

    LOGGER.info("PullRecommendationsJob: #{hop1_candidates} candidates after hop 1, \
      #{candidates.size} after expanding #{hop2_seeds.size} of them")

    return rank(candidates, subscriptions, seed_authors)
  end

  # Seeds from the watch history and the subscription feed, interleaved. The
  # budget usually runs out before the seeds do, so alternating keeps both
  # sources represented instead of spending everything on the history.
  private def seed_ids(user : User) : Array(String)
    history = user.watched.last(HISTORY_SEEDS).reverse

    subscriptions = [] of String
    begin
      channel_videos, _ = get_subscription_feed(user, SUBSCRIPTION_SEEDS, 1)
      subscriptions = channel_videos.select do |v|
        # Live streams and premieres have no useful related videos
        !v.live_now && v.premiere_timestamp.nil? && (v.length_seconds || 0) > 0 && (v.views || 0) > 0
      end.map(&.id)
    rescue ex
      LOGGER.error("PullRecommendationsJob: subscription feed for #{user.email} failed: #{ex.message}")
    end

    seeds = [] of String
    [history.size, subscriptions.size].max.times do |i|
      seeds << history[i] if i < history.size
      seeds << subscriptions[i] if i < subscriptions.size
    end

    return seeds.uniq.reject(&.empty?)
  end

  # Earlier seeds are more recently watched, so what they recommend counts for
  # more. Decays from 1.0 down, never to zero.
  private def seed_weight(index : Int32) : Float64
    return 1.0 / Math.sqrt(1.0 + index)
  end

  # Accumulates everything a seed recommends. Unlike a plain dedupe, seeing the
  # same video again is the point: it adds weight instead of being discarded.
  private def collect(candidates : Hash(String, Candidate), video : Video, weight : Float64, watched : Set(String))
    video.related_videos.each do |related|
      next unless id = related["id"]?

      # Already watched, so not a recommendation
      next if watched.includes?(id)

      # Both keys are always present, but may be empty or "0" when YouTube
      # didn't report them. Comparing against the string matters: these are
      # `String`, so `!= 0` would always be true.
      published = related["published"]?
      next if published.nil? || published.empty?
      next if (related["length_seconds"]? || "0") == "0"

      candidate = candidates[id] ||= Candidate.new(SearchVideo.new({
        title:              related["title"]? || "",
        id:                 id,
        author:             related["author"]? || "",
        ucid:               related["ucid"]? || "",
        published:          (Time.parse_rfc3339(published) rescue Time.utc),
        views:              short_text_to_number(related["short_view_count"]? || "0"),
        description_html:   "", # not available
        length_seconds:     related["length_seconds"]?.try &.to_i || 0,
        premiere_timestamp: nil,
        author_verified:    related["author_verified"]? == "true",
        author_thumbnail:   related["author_thumbnail"]?,
        badges:             VideoBadges::None,
      }))

      candidate.cooccurrence += weight
    end
  end

  # Scores every candidate, caps how much one channel can contribute, and
  # returns the pool ordered best first.
  private def rank(candidates : Hash(String, Candidate), subscriptions : Set(String), seed_authors : Set(String)) : Array(SearchVideo)
    now = Time.utc

    scored = candidates.each_value.map do |candidate|
      video = candidate.video

      score = COOCCURRENCE_WEIGHT * Math.sqrt(candidate.cooccurrence)

      unless video.ucid.empty?
        score += SUBSCRIBED_BOOST if subscriptions.includes?(video.ucid)
        score += AFFINITY_BOOST if seed_authors.includes?(video.ucid)
      end

      # Clamped, since premieres can carry a timestamp in the future
      age_days = (now - video.published).total_days.clamp(0.0, Float64::MAX)
      score += RECENCY_WEIGHT * (1.0 / (1.0 + age_days / RECENCY_HALFLIFE))

      score += VIEWS_WEIGHT * Math.log(1.0 + video.views) / Math.log(1_000_000.0)

      if video.length_seconds > 0 && video.length_seconds < SHORTS_LENGTH
        score *= SHORTS_PENALTY
      end

      {video, score}
    end.to_a

    scored.sort_by! { |_, score| -score }

    pool = [] of SearchVideo
    per_channel = {} of String => Int32

    scored.each do |video, _|
      break if pool.size >= POOL_SIZE

      count = per_channel[video.ucid]? || 0
      next if !video.ucid.empty? && count >= MAX_PER_CHANNEL

      per_channel[video.ucid] = count + 1
      pool << video
    end

    return pool
  end

  # Resolves a seed video. The local `videos` table is checked first, but since
  # it only holds the last six hours it rarely hits on a daily rebuild, so most
  # seeds spend from this rebuild's budget. Each fetch costs two upstream
  # requests (/player and /next).
  private def fetch_seed(id : String) : Video?
    cached = Invidious::Database::Videos.select(id)
    return cached if cached && cached.schema_version == Video::SCHEMA_VERSION

    return nil if @budget <= @budget_floor
    @budget -= 1

    video = get_video(id)
    sleep FETCH_SPACING

    return video
  rescue ex
    LOGGER.debug("PullRecommendationsJob: seed #{id} unavailable: #{ex.message}")
    return nil
  end
end
