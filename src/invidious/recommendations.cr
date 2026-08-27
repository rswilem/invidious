# How much of the ranked pool a single response draws from, as a multiple of
# `recommendations_max_results`. Wider gives more variety between reloads,
# narrower gives a higher quality floor.
RECOMMENDATIONS_RANK_WINDOW = 3

# How many videos are handed back in strict rank order, before the weighted
# draw takes over. These are the "first few results should be a solid hit"
# slots, so they are never randomized.
RECOMMENDATIONS_TOP_RESULTS = 12

# How steeply the weighted draw favours higher-ranked videos. 0.0 is a uniform
# shuffle, 1.0 makes the top of the window roughly an order of magnitude more
# likely than the bottom.
RECOMMENDATIONS_TAIL_BIAS = 0.5

def fetch_user_video_recommendations(env, region, locale)
  user = env.get?("user").try &.as(Invidious::User)

  # API clients such as Yattee call /api/v1/popular without the SID cookie, so
  # there is no session to personalize from. On a single-user instance we can
  # fall back to a configured account instead of returning nothing.
  if user.nil? && (fallback_email = CONFIG.popular_fallback_user)
    user = Invidious::Database::Users.select(email: fallback_email)
  end

  if user.nil?
    return [] of SearchVideo, nil
  end

  # Built and ranked by PullRecommendationsJob, so this path never talks to
  # YouTube. The pool already excludes watched videos.
  pool = Invidious::Jobs::PullRecommendationsJob.pool_for(user.email)

  if user.preferences.unseen_only
    watched = user.watched.to_set
    pool = pool.reject { |video| watched.includes?(video.id) }
  end

  # The pool is ordered best first, so a response only ever draws from the top
  # slice of it. `first` can't raise when the pool is smaller.
  limit = CONFIG.recommendations_max_results
  window = pool.first(limit * RECOMMENDATIONS_RANK_WINDOW)

  # The head goes back in rank order. These are the strongest candidates the
  # job could find, and shuffling them in with the rest of the window gave the
  # 300th-best video the same odds of leading the feed as the 4th.
  #
  # Capped at `limit` as well, so a small `recommendations_max_results` can't be
  # overshot by the head alone.
  top = limit < RECOMMENDATIONS_TOP_RESULTS ? limit : RECOMMENDATIONS_TOP_RESULTS
  head = window.first(top)

  remaining = limit - head.size
  return head, nil if remaining <= 0

  # The tail is a weighted draw rather than a uniform one, so reloading still
  # produces a different mix while better videos keep turning up more often.
  tail = weighted_sample(window[head.size..], remaining)

  return head + tail, nil
end

# Selects `count` videos without replacement, weighted by position: earlier
# entries are more likely to be picked.
#
# Uses the Efraimidis-Spirakis method, which gives every entry a key of
# `-ln(U) / weight` and keeps the smallest ones. That yields a correct weighted
# sample in a single pass, unlike repeatedly drawing and removing.
private def weighted_sample(videos : Array(SearchVideo), count : Int32) : Array(SearchVideo)
  return videos if videos.size <= count

  keyed = videos.map_with_index do |video, index|
    weight = 1.0 / ((1.0 + index) ** RECOMMENDATIONS_TAIL_BIAS)
    {-Math.log(rand) / weight, video}
  end

  keyed.sort_by! { |key, _| key }

  return keyed.first(count).map { |_, video| video }
end
