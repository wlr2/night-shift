"""Fetch selected original asset bytes from the GitHub release, with SHA256 checks.

The default uses HTTP byte ranges: selecting a model downloads only that file and
its linked texture files. --package downloads/extracts a complete verified ZIP.
No external dependencies; works in Claude Code cloud and local Python 3.10+.
"""
import argparse,hashlib,json,pathlib,shutil,sys,urllib.request,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def read(path):return json.loads(path.read_text(encoding='utf8'))
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  while chunk:=f.read(8*1024*1024):h.update(chunk)
 return h.hexdigest()
def target(root,name):
 relative=pathlib.PurePosixPath(name)
 if relative.is_absolute() or '..' in relative.parts or any(':' in part for part in relative.parts):raise ValueError('Unsafe asset path')
 result=root.joinpath(*relative.parts).resolve()
 if not result.is_relative_to(root.resolve()):raise ValueError('Asset escapes output folder')
 return result
def request(url,headers=None):return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'nightshift-asset-fetcher/1',**(headers or {})}),timeout=120)
def seed_metadata(out):
 context=ROOT/'assets/context'
 for file in context.glob('*.json'):
  dest=out/file.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,dest)
 for file in (context/'characters').glob('*.json'):
  dest=out/'characters'/file.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,dest)
def fetch_one(name,manifest,out,cache):
 entry=manifest['files'].get(name)
 if entry is None:raise ValueError('Asset path not in complete release manifest: '+name)
 destination=target(out,name)
 if destination.is_file() and destination.stat().st_size==entry['bytes'] and digest(destination)==entry['sha256']:
  print('Verified cached:',name);return
 package=manifest['packages'][entry['package']];cached=cache/package['file']
 destination.parent.mkdir(parents=True,exist_ok=True);partial=destination.with_name(destination.name+'.partial')
 h=hashlib.sha256()
 try:
  if cached.is_file() and digest(cached)==package['sha256']:
   with zipfile.ZipFile(cached) as archive,archive.open(manifest['rootPrefix']+name) as source,partial.open('wb') as sink:
    while chunk:=source.read(1024*1024):h.update(chunk);sink.write(chunk)
  else:
   end=entry['offset']+entry['bytes']-1
   if entry['bytes']==0:partial.write_bytes(b'')
   else:
    with request(package['url'],{'Range':f'bytes={entry["offset"]}-{end}'}) as source:
     if source.status!=206:raise RuntimeError('Server did not honor a byte-range request. Use --package '+entry['package']+' to cache the complete ZIP.')
     expected_range=f'bytes {entry["offset"]}-{end}/'
     if not source.headers.get('Content-Range','').startswith(expected_range):raise RuntimeError('Unexpected server content range')
     remaining=entry['bytes']
     with partial.open('wb') as sink:
      while remaining:
       chunk=source.read(min(1024*1024,remaining))
       if not chunk:raise RuntimeError('Incomplete asset response')
       remaining-=len(chunk);h.update(chunk);sink.write(chunk)
  if partial.stat().st_size!=entry['bytes'] or h.hexdigest()!=entry['sha256']:raise RuntimeError('Asset checksum mismatch: '+name)
  partial.replace(destination);print('Fetched:',name)
 except Exception:
  partial.unlink(missing_ok=True);raise
def fetch_package(group,manifest,out,cache):
 package=manifest['packages'][group];file=cache/package['file'];cache.mkdir(parents=True,exist_ok=True)
 if not file.is_file() or digest(file)!=package['sha256']:
  partial=file.with_name(file.name+'.partial')
  try:
   with request(package['url']) as source,partial.open('wb') as sink:shutil.copyfileobj(source,sink,8*1024*1024)
   if partial.stat().st_size!=package['bytes'] or digest(partial)!=package['sha256']:raise RuntimeError('Package checksum mismatch')
   partial.replace(file)
  except Exception:partial.unlink(missing_ok=True);raise
 with zipfile.ZipFile(file) as z:
  for info in z.infolist():
   name=info.filename.removeprefix(manifest['rootPrefix'])
   if name==info.filename or name not in manifest['files']:raise ValueError('Unexpected ZIP member')
   destination=target(out,name);destination.parent.mkdir(parents=True,exist_ok=True)
   with z.open(info) as source,destination.open('wb') as sink:shutil.copyfileobj(source,sink,8*1024*1024)
   if digest(destination)!=manifest['files'][name]['sha256']:raise RuntimeError('Extracted file checksum mismatch')
 print('Verified and extracted package:',group)
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--key',action='append',default=[],help='Model catalog key; repeatable')
 parser.add_argument('--texture',action='append',default=[],help='Texture catalog key; repeatable')
 parser.add_argument('--audio',action='append',default=[],help='Audio catalog key; repeatable')
 parser.add_argument('--file',action='append',default=[],help='Exact library-relative file path')
 parser.add_argument('--package',choices=['core','audio','originals'],action='append',default=[])
 parser.add_argument('--all',action='store_true',help='Download all three packages, including every original source file')
 parser.add_argument('--out',type=pathlib.Path,default=ROOT/'assets/library')
 parser.add_argument('--cache',type=pathlib.Path,default=ROOT/'.asset-cache')
 parser.add_argument('--list',action='store_true')
 args=parser.parse_args();manifest=read(ROOT/'assets/library-manifest.json');context=ROOT/'assets/context'
 models={e['key']:e for e in read(context/'catalog.json')['assets']}
 textures={e['key']:e for e in read(context/'texture-catalog.json')['assets']}
 audio={e['key']:e for e in read(context/'audio-catalog.json')['assets']}
 if args.list:print(json.dumps({'models':len(models),'textureGroups':len(textures),'audioTracks':len(audio),'files':len(manifest['files']),'packages':manifest['packages']},indent=2));return
 files=set(args.file)
 for key in args.key:
  if key not in models:parser.error('Unknown model key: '+key)
  model=models[key];files.add(model['preparedFile'])
  for image in model.get('textures',[]):
   name=image.get('path')
   if not name and model['preparedFile'].lower().endswith('.fbx') and image.get('name'):
    name=str(pathlib.PurePosixPath(model['preparedFile']).parent/image['name'])
   if name and name in manifest['files']:files.add(name)
 for key in args.texture:
  if key not in textures:parser.error('Unknown texture key: '+key)
  files.add(textures[key]['preparedFile'])
 for key in args.audio:
  if key not in audio:parser.error('Unknown audio key: '+key)
  files.add(audio[key]['preparedFile'])
 groups=list(manifest['packages']) if args.all else args.package
 if not files and not groups:parser.error('Choose --key, --texture, --audio, --file, --package, --all or --list')
 args.out.mkdir(parents=True,exist_ok=True);seed_metadata(args.out)
 for group in dict.fromkeys(groups):fetch_package(group,manifest,args.out,args.cache)
 for name in sorted(files):fetch_one(name,manifest,args.out,args.cache)
if __name__=='__main__':
 try:main()
 except (ValueError,RuntimeError,urllib.error.URLError) as error:print('Asset fetch failed:',error,file=sys.stderr);sys.exit(1)
