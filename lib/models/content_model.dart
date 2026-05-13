enum ContentType { live, movie, series }

class ContentItem {
  final String id;
  final ContentType type;
  final String title;
  final String? description;
  final String imageUrl;
  final String? backdropUrl;
  final String? genre;
  final String? category;
  final int? year;
  final double? rating;
  final String? duration;
  final int? episodeCount;
  final int? channelNumber;
  final String? nowPlaying;
  final String? nextUp;
  final bool isFavorite;
  final String? videoUrl;
  final String? containerExtension;

  const ContentItem({
    required this.id,
    required this.type,
    required this.title,
    this.description,
    required this.imageUrl,
    this.backdropUrl,
    this.genre,
    this.category,
    this.year,
    this.rating,
    this.duration,
    this.episodeCount,
    this.channelNumber,
    this.nowPlaying,
    this.nextUp,
    this.isFavorite = false,
    this.videoUrl,
    this.containerExtension,
  });

  ContentItem copyWith({bool? isFavorite}) => ContentItem(
        id: id,
        type: type,
        title: title,
        description: description,
        imageUrl: imageUrl,
        backdropUrl: backdropUrl,
        genre: genre,
        category: category,
        year: year,
        rating: rating,
        duration: duration,
        episodeCount: episodeCount,
        channelNumber: channelNumber,
        nowPlaying: nowPlaying,
        nextUp: nextUp,
        isFavorite: isFavorite ?? this.isFavorite,
        videoUrl: videoUrl,
        containerExtension: containerExtension,
      );

  bool get isLive => type == ContentType.live;
  bool get isMovie => type == ContentType.movie;
  bool get isSeries => type == ContentType.series;

  String get displayTitle => title;
  String get typeLabel {
    switch (type) {
      case ContentType.live:
        return 'LIVE';
      case ContentType.movie:
        return 'MOVIE';
      case ContentType.series:
        return 'SERIES';
    }
  }
}

// ── Episode model for series ───────────────────────────────────────────────
class EpisodeInfo {
  final String streamId;   
  final String ext;        
  final String title;
  final int episodeNum;
  final int seasonNum;
  final String? plot;
  final String? duration;
  final String? thumbnail;
  final String? directSource; // direct_source URL from Xtream API (highest priority)

  const EpisodeInfo({
    required this.streamId,
    required this.ext,
    required this.title,
    required this.episodeNum,
    required this.seasonNum,
    this.plot,
    this.duration,
    this.thumbnail,
    this.directSource,
  });

  /// Path used in the series stream URL: "12345.mp4"
  String get streamPath => '$streamId.$ext';

  String get label => 'E$episodeNum';
}

// ── Season model ──────────────────────────────────────────────────────────
class SeasonInfo {
  final int seasonNum;
  final List<EpisodeInfo> episodes;
  const SeasonInfo({required this.seasonNum, required this.episodes});
  String get label => 'Season $seasonNum';
}
