import 'api.dart';

/// What the screens say about where a match or a request is.
///
/// The server stores a code in `stage` (`detecting`, `rendering`, …) and the
/// numbers in their own fields — `n_moments`, `progress`, the clips. The
/// sentence is put together here, so the wording lives with the rest of the
/// interface and a count is never parsed out of text.

const _jobStages = {
  'queued': 'queued',
  'downloading': 'downloading the video',
  'cropping': 'cropping the HUD regions',
  'extracting_audio': 'extracting the audio',
  'detecting': 'detecting events',
  'planning': 'crossing the detectors',
  'error': 'error',
};

String jobStageText(Job job) {
  if (job.isFailed) return 'analysis failed';
  if (job.isReady) {
    final n = job.nMoments;
    if (n == null) return 'analysis complete';
    if (n == 0) return 'no moments found';
    return '$n moment(s) found — open the editor';
  }
  // an unknown code is shown as it came, rather than hiding where it is
  return _jobStages[job.stage] ?? (job.stage.isEmpty ? job.status : job.stage);
}

const _renderStages = {
  'queued': 'queued',
  'preparing': 'preparing the cuts',
  'nothing_chosen': 'nothing chosen',
  'nothing_to_cut': 'nothing can be cut',
  'error': 'error',
  'cancelled': 'cancelled',
};

String renderStageText(Render render) {
  if (render.status == 'done') {
    final withVideo = render.clips.where((c) => !c.onlyCuts).length;
    final cutsOnly = render.clips.length - withVideo;
    return '$withVideo video(s) ready'
        '${cutsOnly > 0 ? ' + $cutsOnly with cuts only' : ''}';
  }
  if (render.stage == 'rendering') {
    return 'rendering (${(render.progress * 100).round()}%)';
  }
  return _renderStages[render.stage] ??
      (render.stage.isEmpty ? render.status : render.stage);
}
