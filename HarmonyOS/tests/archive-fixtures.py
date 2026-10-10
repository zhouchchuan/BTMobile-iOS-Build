"""Exercise the application adapter with real encrypted/multipart archives.
Generated fixtures contain only synthetic text/image/data. RAR fixtures are from
the BSD-licensed libarchive test suite at a fixed source commit.
"""
import binascii
import hashlib
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

exe = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix='btmobie-archive-'))
src = root / '中文样例'
src.mkdir()
(src / '说明.txt').write_text('中文 UTF-8 文件测试\nhttps://example.org/\n', encoding='utf-8')
(src / '图片.png').write_bytes(bytes.fromhex('89504e470d0a1a0a') + bytes(range(256)))
(src / 'data.bin').write_bytes(hashlib.shake_256(b'BTmobie fixture').digest(180000))
seven = shutil.which('7zz') or shutil.which('7z')
assert seven
def command(args):
    subprocess.run(args, cwd=root, check=True, stdout=subprocess.DEVNULL)
def make(name, *args):
    command([seven, 'a', '-y', str(root/name), '中文样例', *args])
def contents(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in folder.rglob('*') if p.is_file()}
expected = contents(root/'中文样例')
counter = 0
def extract(name, password='', fail=None, check_generated=True):
    global counter
    counter += 1
    out = root / ('out-' + str(counter))
    result = subprocess.run([str(exe), str(root/name), str(out), password], text=True, capture_output=True)
    if fail:
        assert result.returncode != 0, (name, 'unexpected success')
        assert fail in result.stderr, (name, result.stderr)
    else:
        assert result.returncode == 0, (name, result.stderr)
        if check_generated: assert contents(out/'中文样例') == expected, (name, contents(out))
    print('PASS', name, 'expected-error' if fail else 'byte-verified' if check_generated else 'extracted')
    return out
for name, args in [
    ('plain.7z', []), ('plain.zip', []),
    ('encrypted.7z', ['-pfixture-pass', '-mhe=on']),
    ('data-encrypted.7z', ['-pfixture-pass']),
    ('aes.zip', ['-pfixture-pass', '-mem=AES256']),
    ('zipcrypto.zip', ['-pfixture-pass', '-mem=ZipCrypto']),
    ('vol.7z', ['-pfixture-pass', '-mhe=on', '-v32k']),
    ('vol.zip', ['-pfixture-pass', '-mem=AES256', '-v32k'])]:
    make(name, *args)
    first = name + '.001' if '-v32k' in args else name
    password = 'fixture-pass' if any(a.startswith('-p') for a in args) else ''
    extract(first, password)
    if password:
        extract(first, '', '密码')
        extract(first, 'wrong-pass', '密码')
    if first.endswith('.001'): extract(name+'.002', password)
for mode, suffix in [('w', 'tar'), ('w:gz', 'tar.gz'), ('w:bz2', 'tar.bz2'), ('w:xz', 'tar.xz')]:
    with tarfile.open(root/('fixture.'+suffix), mode) as tar: tar.add(src, arcname='中文样例')
    extract('fixture.'+suffix)
with tarfile.open(root/'root-dot.tar', 'w') as tar: tar.add(src, arcname='.')
out = extract('root-dot.tar', check_generated=False)
assert contents(out) == expected
command(['zip', '-q', '-r', '-s', '64k', 'split.zip', '中文样例'])
extract('split.zip'); extract('split.z01')
command(['zip', '-q', '-r', '-s', '64k', '中文分卷.zip', '中文样例'])
extract('中文分卷.zip'); extract('中文分卷.z01')
# Missing first/middle parts must be a missing-volume message, not generic corruption.
part = root/'vol.7z.002'; part.rename(root/'vol.7z.002.saved')
extract('vol.7z.001', 'fixture-pass', '分卷')
(root/'vol.7z.002.saved').rename(part)
(root/'vol.7z.001').rename(root/'vol.7z.001.saved')
extract('vol.7z.002', 'fixture-pass', '首个分卷')
(root/'vol.7z.001.saved').rename(root/'vol.7z.001')
with zipfile.ZipFile(root/'traversal.zip','w') as archive: archive.writestr('../outside.txt','must not escape')
extract('traversal.zip', '', '不安全'); assert not (root/'outside.txt').exists()
with tarfile.open(root/'symlink.tar','w') as archive:
    info=tarfile.TarInfo('link'); info.type=tarfile.SYMTYPE; info.linkname='/tmp'; archive.addfile(info)
extract('symlink.tar', '', '不安全')
# Pinned, public, non-personal RAR fixtures; no commercial compressor is needed.
revision='4e97bd559929642d827020b7dffa1fe7483af5e6'
def rar(name):
    encoded=root/(name+'.uu')
    command(['curl','-fL','--retry','4','-sS',f'https://raw.githubusercontent.com/libarchive/libarchive/{revision}/libarchive/test/{name}.uu','-o',str(encoded)])
    lines=encoded.read_bytes().splitlines(); start=next(i for i,line in enumerate(lines) if line.startswith(b'begin '))+1
    data=b''.join(binascii.a2b_uu(line) for line in lines[start:] if line not in (b'end', b'`', b' '))
    (root/name).write_bytes(data)
for version in (4,5):
    for kind in ('encrypted_filenames','solid_encrypted','solid_encrypted_filenames'):
        name=f'test_read_format_rar{version}_{kind}.rar'; rar(name)
        out=extract(name,'password',check_generated=False)
        for letter in 'abcd': assert (out/(letter+'.txt')).read_bytes().rstrip(b'\x00\r\n') == f'This is from {letter}.txt'.encode()
        extract(name,'', '密码',False); extract(name,'wrong','密码',False)
for i in range(1,9): rar(f'test_read_format_rar5_multiarchive.part{i:02}.rar')
out=extract('test_read_format_rar5_multiarchive.part03.rar',check_generated=False)
assert any(out.rglob('*'))
print('ARCHIVE SUITE PASSED:', counter, 'cases')
