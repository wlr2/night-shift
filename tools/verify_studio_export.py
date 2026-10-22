"""Check that the immutable native Studio snapshot matches the export manifest.
Use --check-working-source only before making intentional changes to src/.
"""
import argparse,hashlib,json,pathlib,xml.etree.ElementTree as ET
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sources(file):
 records={}
 def walk(item,parent=''):
  props={p.get('name'):p for p in item.find('Properties')};name=props['Name'].text;path=(parent+'.' if parent else '')+name
  if 'Source' in props:records[path]={'class':item.get('class'),'source':props['Source'].text or ''}
  for child in item.findall('Item'):walk(child,path)
 for item in ET.parse(file).getroot().findall('Item'):walk(item)
 return records
def main():
 p=argparse.ArgumentParser();p.add_argument('--check-working-source',action='store_true');p.add_argument('--compare-build',type=pathlib.Path);args=p.parse_args()
 manifest=json.loads((ROOT/'studio/export-manifest.json').read_text());native=ROOT/manifest['nativeSnapshot'];data=native.read_bytes()
 assert hashlib.sha256(data).hexdigest()==manifest['nativeSnapshotSha256'],'Native snapshot changed'
 exported=sources(native);assert len(exported)==manifest['scriptCount']
 for entry in manifest['scripts']:
  actual=exported[entry['instancePath']];assert actual['class']==entry['className'];source=actual['source'].encode()
  assert hashlib.sha256(source).hexdigest()==entry['sha256']
  if args.check_working_source:assert (ROOT/entry['file']).read_bytes()==source,entry['file']
 if args.compare_build:
  built=sources(args.compare_build);assert built==exported,'Rebuilt script sources differ from native snapshot'
 print(f"Verified {len(exported)} native script sources"+(' and current source files' if args.check_working_source else '')+(' and rebuilt place' if args.compare_build else ''))
if __name__=='__main__':main()
