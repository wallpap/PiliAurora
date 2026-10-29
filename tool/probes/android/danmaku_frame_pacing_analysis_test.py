import unittest

from danmaku_frame_pacing_analysis import continuity, judge, match_frames


class FrameAssociationTest(unittest.TestCase):
    def test_matches_only_swap_inside_same_frame_raster(self):
        stage = dict(frames=[dict(frameNumber=10, targetUs=100, positionUs=100)],
                     timings=[dict(frameNumber=10, rasterStartUs=110, rasterFinishUs=120)])
        native = [dict(id=2, start=112000, end=118000, present=130000),
                  dict(id=1, start=90000, end=95000, present=110000)]
        matched, missing = match_frames(stage, native)
        self.assertEqual([frame['presentNs'] for frame in matched], [130000])
        self.assertFalse(any(missing.values()))

    def test_ambiguous_missing_and_unpresented_frames_are_not_filled(self):
        frames = [dict(frameNumber=i, targetUs=i * 100, positionUs=i * 100) for i in range(3)]
        stage = dict(frames=frames, timings=[dict(frameNumber=i, rasterStartUs=i * 100, rasterFinishUs=i * 100 + 20) for i in (1, 2)])
        native = [dict(id=1, start=101000, end=109000, present=130000),
                  dict(id=2, start=111000, end=119000, present=140000),
                  dict(id=3, start=201000, end=209000, present=0)]
        matched, missing = match_frames(stage, native)
        self.assertEqual(matched, [])
        self.assertEqual(missing['timing'], 1)
        self.assertEqual(missing['ambiguous'], 1)
        self.assertEqual(missing['present'], 1)

    def test_target_is_capped_by_display_but_missing_present_fails(self):
        stage = dict(startedUs=0, endedUs=1000000, before=dict(updates=0),
                     after=dict(updates=60), target=120, refreshHz=60,
                     frames=[dict(scrollCount=1) for _ in range(60)])
        matched = [dict(index=i, targetUs=i * 16667, positionUs=i * 16667, presentNs=i * 16667000 + 1000000) for i in range(60)]
        analysis = continuity.analyze(matched)
        self.assertTrue(judge(stage, matched, analysis)['passed'])
        self.assertFalse(judge(stage, [], continuity.analyze([]))['passed'])
        stage['frames'][0]['scrollCount'] = 0
        self.assertFalse(judge(stage, matched, analysis)['activePassed'])


if __name__ == '__main__':
    unittest.main()
