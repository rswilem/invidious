# How much of the ranked pool a single response draws from, as a multiple of
# `recommendations_max_results`. Wider gives more variety between reloads,
# narrower gives a higher quality floor.
RECOMMENDATIONS_RANK_WINDOW = 3

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

  # The pool is ordered best first, so draw from the top slice and shuffle that
  # rather than the whole pool: a reload still varies, but never dredges up the
  # weakest candidates. `first` can't raise when the pool is smaller.
  limit = CONFIG.recommendations_max_results
  window = pool.first(limit * RECOMMENDATIONS_RANK_WINDOW)

  return window.shuffle.first(limit), nil
end
