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
import re
from datetime import date
from pathlib import Path
from tempfile import NamedTemporaryFile

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
      if re.match(r'^From [0-9a-f]{40}(?:[0-9a-f]{24})? ', l):
        added_patch_location = False
      line_has_correct_start = l.startswith('diff -') or l.startswith('---')
      if not added_patch_location and line_has_correct_start:
        ret.append(f'{PATCH_DIR_PREFIX}{patch_dir}\n')
        ret.append(f'{PATCH_FILENAME_PREFIX}{patch_filename}\n')
        added_patch_location = True
      ret.append(l)
  return ''.join(ret)


def patch_from_dir(patch_dir, manifest=None):
  """Read the selected ordered collection as mail suitable for git am."""
  manifest = resolve_manifest(patch_dir, manifest)
  patch_list = read_manifest(patch_dir, manifest)
  return ''.join(read_patch(patch_dir, filename) for filename in patch_list)


def resolve_manifest(patch_dir, manifest=None):
  """Require an explicit selection when the directory uses channel manifests."""
  if manifest is None:
    if any((Path(patch_dir) / name).exists() for name in CHANNEL_MANIFESTS):
      raise ValueError('Select a channel with --channel or a manifest with --manifest')
    manifest = '.patches'
  if manifest not in ('.patches', *CHANNEL_MANIFESTS):
    raise ValueError(f'Unsupported patch manifest: {manifest}')
  return manifest


CHANNEL_MANIFESTS = tuple(f'.patches-{channel}' for channel in ('master', 'beta', 'stable'))


def read_manifest(patch_dir, manifest, required=True):
  """Read a manifest and check that each change selects one safe filename."""
  file = Path(patch_dir) / manifest
  if file.is_symlink():
    raise ValueError(f'{manifest} must be a regular file')
  if not file.exists() and not required:
    return []
  entries = file.read_text(encoding='utf-8').splitlines()
  if required and not entries:
    raise ValueError(f'{manifest} must list at least one patch')
  validate_patch_names(entries, manifest)
  for name in entries:
    if (Path(patch_dir) / name).is_symlink():
      raise ValueError(f'{manifest}: patch paths cannot contain symlinks: {name}')
  return entries


def validate_patch_names(entries, manifest):
  selected = set()
  identities = set()
  for name in entries:
    if (not name or name != name.strip() or not name.endswith('.patch') or
        '/' in name or '\\' in name or ':' in name or name in ('.patch', '..patch')):
      raise ValueError(f'{manifest}: expected a patch filename in the collection root: {name!r}')
    if name in selected:
      raise ValueError(f'{manifest}: duplicate entry: {name}')
    selected.add(name)
    identity = patch_identity(name)
    if identity in identities:
      raise ValueError(f'{manifest}: multiple variants of {identity}')
    identities.add(identity)


def patch_identity(name):
  stem = name[:-len('.patch')]
  adaptation = re.search(r'_(\d{4}-\d{1,2}-\d{1,2})$', stem)
  if adaptation:
    date_text = adaptation.group(1)
    try:
      parsed = date.fromisoformat(date_text)
    except ValueError:
      raise ValueError(f'Invalid adaptation date: {date_text}') from None
    if parsed.isoformat() != date_text:
      raise ValueError(f'Invalid adaptation date: {date_text}')
    stem = stem[:adaptation.start()]
  if not stem:
    raise ValueError(f'Patch filename must include a change name: {name}')
  return stem


def write_patch_collection(patch_dir, manifest, patches, partial=False,
                           update_shared=False, dry_run=False):
  """Export one selection while preserving other manifests and their patches."""
  root = Path(patch_dir)
  previous = read_manifest(root, manifest, required=False)
  references = set()
  for other in ('.patches', *CHANNEL_MANIFESTS):
    if other != manifest:
      references.update(read_manifest(root, other, required=False))

  entries = list(patches)
  validate_patch_names(entries, manifest)
  if partial:
    replacements = {patch_identity(name): name for name in patches}
    entries = [replacements.pop(patch_identity(name), name) for name in previous]
    entries.extend(replacements.values())
  validate_patch_names(entries, manifest)
  if not entries:
    raise ValueError(f'{manifest}: export would leave an empty collection')

  changed = []
  for name, contents in patches.items():
    target = root / name
    if target.is_symlink():
      raise ValueError(f'Patch paths cannot contain symlinks: {name}')
    if not target.exists() or target.read_bytes() != contents:
      if name in references and target.exists() and not update_shared:
        raise ValueError(
          f'{name} is shared with another manifest; create a dated adaptation '
          'or use --update-shared to change it for all consumers')
      changed.append(name)
  manifest_contents = ''.join(f'{name}\n' for name in entries).encode('utf-8')
  manifest_file = root / manifest
  if not manifest_file.exists() or manifest_file.read_bytes() != manifest_contents:
    changed.append(manifest)
  removed = set(previous) - set(entries) - references
  if dry_run:
    if changed or removed:
      raise ValueError('Export would change: ' + ', '.join([*changed, *sorted(removed)]))
    return

  root.mkdir(parents=True, exist_ok=True)
  for name in changed:
    if name != manifest:
      _write_file(root / name, patches[name])
  if manifest in changed:
    _write_file(manifest_file, manifest_contents)
  for name in removed:
    (root / name).unlink(missing_ok=True)


def _write_file(target, contents):
  # Replace complete files so an interrupted write cannot truncate a patch.
  with NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
    try:
      temporary.write(contents)
      temporary.close()
      os.chmod(temporary.name, target.stat().st_mode & 0o777 if target.exists() else 0o644)
      os.replace(temporary.name, target)
    finally:
      Path(temporary.name).unlink(missing_ok=True)
