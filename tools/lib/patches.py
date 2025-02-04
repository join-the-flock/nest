#!/usr/bin/env python3

# Copyright (c) Electron contributors
# Copyright (c) 2013-2020 GitHub Inc.

# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import codecs
import os

PATCH_DIR_PREFIX = "Patch-Dir: "
PATCH_FILENAME_PREFIX = "Patch-Filename: "
PATCH_LINE_PREFIXES = (PATCH_DIR_PREFIX, PATCH_FILENAME_PREFIX)


def is_patch_location_line(line):
  return line.startswith(PATCH_LINE_PREFIXES)

def read_patch(patch_dir, patch_filename):
  """Read a patch from |patch_dir/filename| and amend the commit message with
  metadata about the patch file it came from."""
  ret = []
  added_patch_location = False
  patch_path = os.path.join(patch_dir, patch_filename)
  with codecs.open(patch_path, encoding='utf-8') as f:
    for l in f.readlines():
      line_has_correct_start = l.startswith('diff -') or l.startswith('---')
      if not added_patch_location and line_has_correct_start:
        ret.append(f'{PATCH_DIR_PREFIX}{patch_dir}\n')
        ret.append(f'{PATCH_FILENAME_PREFIX}{patch_filename}\n')
        added_patch_location = True
      ret.append(l)
  return ''.join(ret)


def patch_from_dir(patch_dir):
  """Read a directory of patches into a format suitable for passing to
  'git am'"""
  with open(os.path.join(patch_dir, ".patches"), encoding='utf-8') as file_in:
    patch_list = [line.rstrip('\n') for line in file_in.readlines()]

  return ''.join([
    read_patch(patch_dir, patch_filename)
    for patch_filename in patch_list
  ])
