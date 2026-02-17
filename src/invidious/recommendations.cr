def fetch_user_video_recommendations(env, region, locale)
  user = env.get?("user").try &.as(Invidious::User)
  if user.nil?
    return [] of SearchVideo, nil
  end

  # Get some new videos from the subscription feed
  channel_videos, _ = get_subscription_feed(user, 5, 1)
  valid_channel_videoids = channel_videos.select do |v|
    # Make sure the video is not live, not a premiere, has a length and has views
    !v.live_now && v.premiere_timestamp.nil? && (v.length_seconds || 0) > 0 && (v.views || 0) > 0
  end.map(&.id)

  # Get the last 10 watched videos
  watched_video_ids = user.watched.last(10)

  video_ids = watched_video_ids + valid_channel_videoids.sample(3)
  video_ids = video_ids.uniq
  video_ids = video_ids.reject(&.nil?)
  video_ids = video_ids.reject(&.empty?)

  if video_ids.empty?
    return [] of SearchVideo, nil
  end

  # Fetch related videos for each video and return 5 random ones
  videos = [] of SearchVideo
  video_ids.each do |video_id|
    video = get_video(video_id)
    next unless video.video_type == VideoType::Video

    if !user.preferences.unseen_only || !user.watched.includes?(video.id)
      videos << SearchVideo.new({
        title:              video.title,
        id:                 video.id,
        author:             video.author,
        ucid:               video.ucid || "",
        published:          video.published || Time.utc,
        views:              video.views || 0_i64,
        description_html:   "", # not available
        length_seconds:     video.length_seconds || 0,
        premiere_timestamp: video.premiere_timestamp,
        author_verified:    video.author_verified,
        author_thumbnail:   video.author_thumbnail,
        badges:             VideoBadges::None,
      })
    end

    next unless video.related_videos

    related = video.related_videos.sample(5)
    related.each do |related_video|
      next unless id = related_video["id"]?
      next unless related_video["published"]?
      next unless related_video["length_seconds"]? && related_video["length_seconds"]? != 0
      next if user.preferences.unseen_only && user.watched.includes?(related_video["id"]?)

      videos << SearchVideo.new({
        title:              related_video["title"],
        id:                 id,
        author:             related_video["author"],
        ucid:               related_video["ucic"]? || "",
        published:          (Time.parse_rfc3339(related_video["published"].to_s) rescue Time.utc),
        views:              short_text_to_number(related_video["short_view_count"]? || "0").to_i64,
        description_html:   "", # not available
        length_seconds:     related_video["length_seconds"]?.try &.to_i || 0,
        premiere_timestamp: nil,
        author_verified:    related_video["author_verified"]? == "true",
        author_thumbnail:   related_video["author_thumbnail"]?,
        badges:             VideoBadges::None,
      })
    end
  end

  return videos.shuffle.uniq(&.id), nil
end
