import copy
import json
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

from recscribe.audio import inspect_wav
from recscribe.channel_windows import ChannelPolicy, recognition_regions, transcribe_regions
from recscribe.job import Job, validate
from recscribe.process import Cancellation, Cancelled
from recscribe.storage import sha256, write_json
from test_pipeline import FFMPEG, SyntheticEngine


class ChannelWindowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / "stereo.wav"
        self.cancel = Cancellation(self.root / "cancel")
        # Three exact windows, one distinct window, and an exact tail. Small PCM
        # rate keeps fixtures cheap; working ASR files still normalize to 16 kHz.
        self.rate = 8000
        samples = (np.sin(np.arange(self.rate * 121) * 0.2) * 8000).astype('<i2')
        stereo = np.column_stack((samples, samples))
        stereo[self.rate * 61:self.rate * 62, 1] = -stereo[self.rate * 61:self.rate * 62, 1]
        with wave.open(str(self.source), 'wb') as audio:
            audio.setparams((2, 2, self.rate, 0, 'NONE', 'PCM')); audio.writeframes(stereo.tobytes())

    def test_windows_cover_exact_frames_and_only_differences_get_context(self):
        report = inspect_wav(self.source, self.cancel)
        windows = report['channel_windows']['windows']
        self.assertEqual([w['bit_identical'] for w in windows], [True, True, False, True, True])
        self.assertEqual(windows[-1]['end_frame'], report['frames'])
        self.assertEqual(recognition_regions(report, 1), [[58 * self.rate, 92 * self.rate]])
        self.assertIsNone(recognition_regions(report, 0))
        broken = copy.deepcopy(report); broken['channel_windows']['windows'][1]['start_frame'] += 1
        with self.assertRaises(ValueError): recognition_regions(broken, 1)
        self.assertIsNone(recognition_regions(report, 1, ChannelPolicy(maximum_regions=0)))

    def test_no_sharing_for_distinct_all_windows_or_more_than_two_channels(self):
        report = inspect_wav(self.source, self.cancel)
        for window in report['channel_windows']['windows']: window['bit_identical'] = False
        self.assertIsNone(recognition_regions(report, 1))
        report['channels'] = 3
        self.assertIsNone(recognition_regions(report, 1))

    def test_region_timing_raw_hashes_and_cancellation(self):
        report = inspect_wav(self.source, self.cancel)
        working = self.root / 'working.wav'
        with wave.open(str(working), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', 'PCM')); audio.writeframes(b'\x01\x00' * (16000 * 121))
        engine = SyntheticEngine()
        result = transcribe_regions(engine, working, self.root / 'asr', 'de', self.cancel, report, recognition_regions(report, 1))
        self.assertEqual(result.segments[0]['start_ms'], 58000)
        self.assertEqual(result.segments[0]['end_ms'], 58900)
        index = json.loads(result.raw_path.read_text())
        record = index['regions'][0]
        self.assertEqual(sha256(self.root / record['path']), record['sha256'])
        self.assertIn('synthetic_test_only', json.loads((self.root / record['path']).read_text()))
        self.assertEqual(record['duration_ms'], 34000)
        self.cancel.event.set()
        with self.assertRaises(Cancelled):
            transcribe_regions(engine, working, self.root / 'cancelled', 'de', self.cancel, report, recognition_regions(report, 1))

    def test_full_job_shares_stereo_without_rewriting_source_and_verifies_regions(self):
        if not FFMPEG.is_file(): self.skipTest('ffmpeg unavailable')
        digest = sha256(self.source)
        class MeasuringEngine(SyntheticEngine):
            def __init__(self, text): super().__init__(text); self.durations = []
            def transcribe(self, audio, output, language, cancel):
                with wave.open(str(audio), 'rb') as source: self.durations.append(source.getnframes() / source.getframerate())
                return super().transcribe(audio, output, language, cancel)
        primary, verifier = MeasuringEngine('one'), MeasuringEngine('two')
        options = dict(source_language='en', target_language=None, mode='verbatim', profile='verified',
                       diarize='off', local_only=True, formats=['json', 'md', 'txt', 'srt', 'vtt'])
        job = Job(self.root / 'job', self.source, options)
        document = job.run(primary, FFMPEG, verifier)
        validate(document)
        self.assertEqual(primary.durations, [121, 34]); self.assertEqual(verifier.durations, [121, 34])
        self.assertEqual(sha256(self.source), digest)
        self.assertEqual([s['channel'] for s in document['segments']], [0, 1])
        self.assertEqual(document['segments'][1]['start_ms'], 58000)
        raw = json.loads((job.directory / 'transcript.raw.json').read_text())
        self.assertTrue(any(r['status'] == 'shared_outside_different_regions' for r in raw['outputs']))

    def test_session_offsets_region_results_without_collapsing_missing_audio(self):
        if not FFMPEG.is_file(): self.skipTest('ffmpeg unavailable')
        lead = self.root / 'lead.wav'
        with wave.open(str(lead), 'wb') as audio:
            audio.setparams((2, 2, self.rate, 0, 'NONE', 'PCM')); audio.writeframes(b'\x01\x00\x01\x00' * self.rate)
        parts = []
        cursor = 0
        for source in [lead, self.source]:
            with wave.open(str(source), 'rb') as audio: frames = audio.getnframes()
            parts.append(dict(path=source.name, startSample=cursor, frames=frames,
                              sizeBytes=source.stat().st_size, sha256=sha256(source), status='verified'))
            cursor += frames
        manifest = self.root / 'session.recscribe.json'
        write_json(manifest, dict(schemaVersion=1, id='synthetic', status='completed', sampleRate=self.rate,
                                 channels=2, bitDepth=16, channelMap=['left', 'right'], parts=parts, issues=[]))
        options = dict(source_language='en', target_language=None, mode='verbatim', profile='fast',
                       diarize='off', local_only=True, formats=['json', 'md', 'txt', 'srt', 'vtt'])
        result = Job(self.root / 'session-job', manifest, options).run(SyntheticEngine(), FFMPEG)
        validate(result)
        self.assertEqual([s['start_ms'] for s in result['segments']], [0, 1000, 59000])
        self.assertEqual(result['source']['duration_ms'], 122000)


if __name__ == '__main__': unittest.main()
