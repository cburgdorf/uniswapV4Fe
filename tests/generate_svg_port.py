#!/usr/bin/env python3
"""Regenerate pinned SVG/Descriptor text composition; numeric helpers stay hand-ported.

Solidity's AST supplies exact concatenated literal bytes, including Unicode.
Only the expression/statement forms used by the listed template functions are
accepted; an unknown construct fails rather than guessing its translation.
Every compiler input is checked against reference_manifest.json first.
"""
from pathlib import Path
import argparse, hashlib, json, re, subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference-core', type=Path, required=True)
parser.add_argument('--reference-periphery', type=Path, required=True)
parser.add_argument('--reference-openzeppelin', type=Path, required=True)
parser.add_argument('--reference-solmate', type=Path, required=True)
parser.add_argument('--solc', type=Path, required=True)
parser.add_argument('--library', choices=['SVG', 'Descriptor'], default='SVG')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
manifest = json.loads((root / 'reference_manifest.json').read_text())
sources = {}
for name, directory, prefix in [
    ('v4-core', args.reference_core, 'core/'),
    ('openzeppelin', args.reference_openzeppelin, 'openzeppelin/'),
    ('solmate', args.reference_solmate, 'solmate/'),
    ('v4-periphery', args.reference_periphery, 'periphery/'),
]:
    for source, record in manifest[name]['sources'].items():
        if not source.endswith('.sol'):
            continue
        if name == 'v4-core' and (not source.startswith('src/') or source.startswith('src/test/')):
            continue
        if name == 'v4-periphery' and source not in ['src/libraries/SVG.sol', 'src/libraries/Descriptor.sol', 'src/libraries/HexStrings.sol']:
            continue
        data = (directory / source).read_bytes()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'Reference hash mismatch: {name}/{source}')
        sources[prefix + source] = {'content': data.decode()}
version = subprocess.check_output([str(args.solc.resolve()), '--version'], text=True)
if '0.8.26+' not in version:
    raise ValueError('Pinned SVG generation requires solc 0.8.26')
request = {'language': 'Solidity', 'sources': sources, 'settings': {
    'remappings': ['@uniswap/v4-core/=core/', 'openzeppelin-contracts/=openzeppelin/', 'solmate/=solmate/'],
    'outputSelection': {'*': {'': ['ast']}},
}}
result = subprocess.run([str(args.solc.resolve()), '--standard-json'], input=json.dumps(request), text=True, capture_output=True, check=True)
compiled = json.loads(result.stdout)
errors = [error for error in compiled.get('errors', []) if error['severity'] == 'error']
if errors:
    raise ValueError(errors)
ast = compiled['sources'][f'periphery/src/libraries/{args.library}.sol']['ast']
contract=next(x for x in ast['nodes'] if x['nodeType']=='ContractDefinition')
nodes={n.get('name'):n for n in contract['nodes'] if 'name' in n}
literals={}
def literal(data):
 if data not in literals:literals[data]=f'literal_{len(literals)}'
 return literals[data]+'()'
def typ(node):
 t=node['typeDescriptions']['typeString']
 if 'string' in t:return 'DynString'
 if t=='address':return 'Address'
 if t=='int24':return 'Int24'
 if t=='int8':return 'i8'
 if t=='uint256':return 'u256'
 if t=='uint8':return 'u8'
 if t=='bool':return 'bool'
 if t=='uint24':return 'Uint24'
 if 'ConstructTokenURIParams' in t:return 'ConstructTokenURIParams'
 if 'SVGParams' in t:return 'SVGParams'
 raise ValueError(t)
def ex(n):
 kind=n['nodeType']
 if kind=='Literal':
  if n['kind'] in ('string','unicodeString'):return literal(n['hexValue'])
  return n['value'].replace('_','')
 if kind=='TupleExpression':
  assert len(n['components'])==1
  return ex(n['components'][0])
 if kind=='Identifier':
  if n['name'] in [f'curve{i}' for i in range(1,9)]:return ex(nodes[n['name']]['value'])
  return n['name']
 if kind=='UnaryOperation':return '('+n['operator']+ex(n['subExpression'])+')'
 if kind=='BinaryOperation':
  left,right=n['leftExpression'],n['rightExpression']
  if left['typeDescriptions']['typeString']=='address' and right['typeDescriptions']['typeString']=='address':
   return '('+ex(left)+'.inner '+n['operator']+' '+ex(right)+'.inner)'
  return '('+ex(left)+' '+n['operator']+' '+ex(right)+')'
 if kind=='Conditional':return '(if '+ex(n['condition'])+' { '+ex(n['trueExpression'])+' } else { '+ex(n['falseExpression'])+' })'
 if kind=='MemberAccess':return ex(n['expression'])+('.len()' if n['memberName']=='length' else '.'+n['memberName'])
 if kind=='FunctionCall':
  f=n['expression'];args=n['arguments']
  if f['nodeType']=='ElementaryTypeNameExpression':
   t=f['typeName']['name'];value=ex(args[0])
   if t in ('string','bytes'):return value
   if t=='address':return '(Address { inner: '+value+' })'
   if args[0]['typeDescriptions']['typeString']=='address':value+=' .inner'
   return '('+value+' as u256)'
  if f['nodeType']=='MemberAccess':
   member=f['memberName'];owner=f['expression']
   if member=='encodePacked':return 'text::concat(['+', '.join('('+ex(a)+').payload_span()' for a in args)+'])'
   if member=='encode' and owner.get('name')=='Base64':return 'text::base64(('+ex(args[0])+').payload_span())'
   if member=='toString':return 'text::decimal('+ex(owner)+')'
   if member=='toHexString':return 'text::concat([text::word(0x3078000000000000000000000000000000000000000000000000000000000000, 2).payload_span(), text::hex('+ex(owner)+', '+ex(args[0])+').payload_span()])'
   raise ValueError(f)
  return ex(f)+'('+', '.join(ex(a) for a in args)+')'
 raise ValueError(n)
def stmt(n,indent='    '):
 k=n['nodeType']
 if k=='Block':return ''.join(stmt(x,indent) for x in n['statements'])
 if k=='VariableDeclarationStatement':
  names=[d['name'] for d in n['declarations']]
  lhs=names[0] if len(names)==1 else '('+', '.join(names)+')'
  return indent+'let '+lhs+' = '+ex(n['initialValue'])+'\n'
 if k=='ExpressionStatement':
  e=n['expression'];assert e['nodeType']=='Assignment' and e['operator']=='='
  return indent+ex(e['leftHandSide'])+' = '+ex(e['rightHandSide'])+'\n'
 if k=='Return':return indent+'return '+ex(n['expression'])+'\n'
 if k=='IfStatement':
  out=indent+'if '+ex(n['condition'])+' {\n'+stmt(n['trueBody'],indent+'    ')+indent+'}'
  if n['falseBody']:out+=' else {\n'+stmt(n['falseBody'],indent+'    ')+indent+'}'
  return out+'\n'
 raise ValueError(n)
selected=['generateSVG','generateSVGDefs','generateSVGBorderText','generateSVGCardMantle','generageSvgCurve','generateSVGCurveCircle','generateSVGPositionDataAndLocationCurve','generateSVGRareSparkle']
if args.library == 'SVG':
 imports = 'svg_math::{getCurve, substring, tickToString, rangeLocation, isRare}'
 struct_name = 'SVGParams'
else:
 selected = ['constructTokenURI', 'generateDescriptionPartOne', 'generateDescriptionPartTwo', 'generateName']
 imports = 'descriptor_format::{fee as feeToPercentString, tick_price as tickToDecimalString}, metadata_text::escape as escapeSpecialCharacters, descriptor_image::{addressToString, generateSVGImage}'
 struct_name = 'ConstructTokenURIParams'
parts=[f'// SPDX-License-Identifier: MIT\n// Generated text composition from pinned {args.library}.sol.\nuse core::ops::Eq\nuse std::abi::{{DynString, sol::{{Int24, Uint24}}}}\nuse std::evm::{{Address, RawMem}}\nuse super::{{metadata_text as text, {imports}}}\n']
if args.library == 'SVG':
 parts=['// SPDX-License-Identifier: MIT\n// Generated text composition from pinned SVG.sol; numeric helpers are in svg_math.fe.\nuse core::ops::Eq\nuse std::abi::{DynString, sol::Int24}\nuse std::evm::{Address, RawMem}\nuse super::{metadata_text as text, svg_math::{getCurve, substring, tickToString, rangeLocation, isRare}}\n']
struct=nodes[struct_name];parts.append('pub struct '+struct_name+' {\n'+''.join('    pub '+m['name']+': '+typ(m)+',\n' for m in struct['members'])+'}\n')
for name in selected:
 fn=nodes[name];params=', '.join('_ '+p['name']+': '+typ(p) for p in fn['parameters']['parameters'])
 body=stmt(fn['body']);ret=fn['returnParameters']['parameters'][0].get('name')
 if ret and fn['body']['statements'][-1]['nodeType'] != 'Return':body='    let mut '+ret+' = text::from_span(core::ptr::MemSpan::empty())\n'+body+'    '+ret+'\n'
 parts.append('pub fn '+name+'('+params+') -> DynString uses (mem: mut RawMem) {\n'+body+'}\n')
if args.library == 'SVG':
 parts.append('pub fn curvePath(_ index: u8) -> DynString uses (mem: mut RawMem) {\n')
 for i in range(1,8):parts.append(f'    if index == {i} {{ return '+ex(nodes[f'curve{i}']['value'])+' }\n')
 parts.append('    '+ex(nodes['curve8']['value'])+'\n}\n')
for data,name in literals.items():
 b=bytes.fromhex(data);size=((len(b)+31)//32)*32
 parts.append(f'// {json.dumps(b.decode("utf-8"),ensure_ascii=False)}\nfn {name}() -> DynString uses (mem: mut RawMem) {{\n    let data = core::ptr::alloc_bytes({size})\n')
 for offset in range(0,len(b),32):parts.append(f'    mem.mstore(addr: core::ptr::offset_bytes(data, {offset}), value: 0x{b[offset:offset+32].hex():0<64})\n')
 parts.append(f'    text::from_span(core::ptr::MemSpan::from_raw_parts(ptr: data, len: {len(b)}))\n}}\n')
args.output.write_text('\n'.join(parts));print(len(literals),'literals')
