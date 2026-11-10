#!/usr/bin/env python3
"""Pure preference-merge controls; no app or device mutation."""
import unittest
from promote import merged_config
class Preferences(unittest.TestCase):
 def test_preserves_unrelated_values_and_comments(self):
  before='# codec=comment\n[core]\nother=value\ncodec=old\n[avcodec]\navcodec-hurry-up=1\n'
  self.assertEqual(merged_config(before),'# codec=comment\n[core]\nother=value\ncodec=avcodec\n[avcodec]\navcodec-hurry-up=0\n')
 def test_duplicates_removed_without_extra_changes(self):
  self.assertEqual(merged_config('codec=a\ncodec=b\n'), 'codec=avcodec\navcodec-hurry-up=0\n')
 def test_idempotent(self):
  once=merged_config('[core]\ncustom=yes');self.assertEqual(once,merged_config(once))
 def test_empty_profile(self):self.assertEqual(merged_config(''),'codec=avcodec\navcodec-hurry-up=0\n')
if __name__=='__main__':unittest.main()
