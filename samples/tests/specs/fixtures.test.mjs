import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,readFileSync,readdirSync,cpSync,mkdtempSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {resolve,dirname,extname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {XMLValidator,XMLParser} from 'fast-xml-parser';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..','..');
const read=p=>readFileSync(resolve(root,p),'utf8');
const manifest=JSON.parse(read('manifest.yaml')); // JSON is a valid YAML 1.2 document.
const parser=new XMLParser({ignoreAttributes:false});
const targets=new Set(['gallery app','custom SAML','OIDC re-integration','App Proxy or Private Access','retire','needs analysis']);
const canonicalUseCases={hr:'UC-01',zoom:'UC-02',student:'UC-03',drupal:'UC-04',alumni:'UC-05',events:'UC-06'};
test('canonical use-case identities are fixed across manifest, fixtures and expected answers',()=>{
  assert.equal(manifest.samples.filter(sample=>sample.useCase.startsWith('UC')).length,6);
  for(const [id,useCase] of Object.entries(canonicalUseCases)){
    const sample=manifest.samples.find(sample=>sample.id===id);
    assert.ok(sample,id);
    assert.equal(sample.useCase,useCase,`${id} canonical use case`);
    assert.equal(JSON.parse(read(sample.expected)).useCase,useCase,`${id} expected answer`);
    for(const path of sample.ingestPaths){
      const source=read(path);
      const fixtureUseCase=path.endsWith('.json')?JSON.parse(source).useCase:parser.parse(source).Export['@_useCase'];
      assert.equal(fixtureUseCase,useCase,`${id} ingest evidence`);
    }
  }
  for(const sample of manifest.samples.filter(sample=>!(sample.id in canonicalUseCases)))assert.match(sample.useCase,/^S\d{2}$/,`${sample.id} remains explicitly synthetic`);
});
test('manifest names exactly twenty-one unique applications and resolvable dependencies',()=>{
  assert.equal(manifest.samples.length,21);
  assert.equal(new Set(manifest.samples.map(s=>s.id)).size,21);
  for(const p of [manifest.shared.compose,manifest.shared.environment,manifest.shared.users,...manifest.shared.bootstrap,...manifest.shared.dependencies])assert.ok(existsSync(resolve(root,p)),p);
  const users=JSON.parse(read(manifest.shared.users));
  assert.equal(users.length,7);
  const seen=new Set();
  for(const sample of manifest.samples){
    for(const p of [sample.path,sample.expected,...sample.ingestPaths,...sample.auxiliaryPaths])assert.ok(existsSync(resolve(root,p)),p);
    if(sample.playwright!=='notApplicable')assert.ok(existsSync(resolve(root,sample.playwright)),sample.playwright);
    else assert.match(sample.howToStart,/notApplicable/);
    for(const uid of sample.testUsers)assert.ok(users.some(u=>u.uid===uid),uid);
    const expected=JSON.parse(read(sample.expected));
    assert.equal(expected.id,sample.id);
    assert.ok(targets.has(expected.entraTargetPattern),sample.id);
    assert.ok(['low','medium','high','unknown'].includes(expected.complexityBand));
    for(const key of ['protocol','entityId','attributes','accountLink','authorization','matchingUsers','reasons','secretFields'])assert.ok(key in expected,`${sample.id}.${key}`);
    assert.deepEqual(expected.matchingUsers,sample.testUsers,`${sample.id} curated assignment cohort`);
    assert.ok(expected.reasons.length>0);
    assert.doesNotMatch(JSON.stringify(expected),/FAKE-EXPORT-ONLY/);
    sample.ingestPaths.forEach(p=>{assert.ok(!seen.has(p),'each fixture belongs to one app');seen.add(p);});
  }
  const fixtureFiles=readdirSync(resolve(root,'config/ingest')).filter(f=>['.json','.xml'].includes(extname(f)));
  assert.equal(fixtureFiles.length,21);
  assert.deepEqual(new Set(fixtureFiles.map(f=>'config/ingest/'+f)),seen);
});
test('exactly one malformed fixture; all remaining JSON and XML parse',()=>{
  const malformed=[];
  for(const sample of manifest.samples)for(const path of sample.ingestPaths){
    try {
      if(path.endsWith('.json'))JSON.parse(read(path));
      else {assert.equal(XMLValidator.validate(read(path)),true,path);parser.parse(read(path));}
    }catch{malformed.push(sample.id);}
  }
  assert.deepEqual(malformed,['broken']);
  assert.equal(JSON.parse(read('expected/broken.json')).parseErrorExpected,true);
});
test('fixtures carry expected identifiers and attribute evidence without copying secrets',()=>{
  for(const sample of manifest.samples.filter(s=>s.id!=='broken')){
    const expected=JSON.parse(read(sample.expected));
    const source=sample.ingestPaths.map(read).join('\n');
    const evidence=sample.ingestPaths[0].endsWith('.json')?JSON.stringify(JSON.parse(source)):source;
    if(expected.entityId!==null){
      if(sample.id==='oidc')assert.equal(JSON.parse(source).client_id,expected.entityId);
      else if(sample.id==='hr'||sample.id==='alumni'||sample.id==='events')assert.equal(JSON.parse(source).serviceId,expected.entityId+'.*');
      else if(source.trim().startsWith('{'))assert.equal(JSON.parse(source).serviceId,expected.entityId);
      else assert.ok(source.includes(expected.entityId),sample.id);
    }
    for(const attribute of expected.attributes)assert.ok(evidence.includes(attribute),`${sample.id}: ${attribute}`);
  }
});
test('advanced ingest cases and synthetic redaction evidence remain isolated',()=>{
  assert.match(read('config/ingest/lab.xml'),/ScriptedAttribute/);
  assert.match(read('config/ingest/payroll.xml'),/refeds.org\/profile\/mfa/);
  assert.match(read('config/ingest/payroll.xml'),/encryptAssertions="true"/);
  assert.match(read('config/ingest/research.xml'),/AttributeFilterPolicy/);
  assert.match(read('config/ingest/research.xml'),/FAKE-EXPORT-ONLY-not-a-password/);
  assert.match(read('config/ingest/research.xml'),/BEGIN PRIVATE KEY/);
  assert.match(read('config/ingest/oidc.json'),/FAKE-EXPORT-ONLY-client-secret/);
  assert.deepEqual(JSON.parse(read('expected/empty.json')).matchingUsers,[]);
  assert.equal(JSON.parse(read('expected/empty.json')).entraTargetPattern,'needs analysis');
  assert.equal(JSON.parse(read('expected/archive.json')).entraTargetPattern,'retire');
  assert.ok(JSON.parse(read('config/ingest/admissions.json')).serviceId.includes('[0-9]+'));
  assert.match(read('config/ingest/clubs.json'),/BACK_CHANNEL/);
  assert.doesNotMatch(read('compose.yaml'),/config\/ingest/);
});
test('seven LDAP identities carry every required attribute and consistent group seeds',()=>{
  const users=JSON.parse(read('idp/ldap/users.json'));
  for(const user of users)for(const key of ['uid','mail','displayName','employeeNumber','eduPersonAffiliation','eduPersonPrincipalName','givenName','sn','groups'])assert.ok(user[key]?.length,`${user.uid}.${key}`);
  assert.equal(new Set(users.map(u=>u.uid)).size,7);
  assert.ok(users.find(u=>u.uid==='erin').eduPersonAffiliation.includes('alum'));
});
test('generated IdP metadata authorizes the literal synthetic principal scope',()=>{
  const temporary=mkdtempSync(resolve(tmpdir(),'idpdemo-metadata-'));
  try {
    const files=['scripts/configure.mjs','.env.sample','manifest.yaml','idp/ldap/users.json',
      'gateway/nginx.conf.template','idp/cas/cas.properties.template',
      ...['idp.properties','ldap.properties','attribute-resolver.xml','attribute-filter.xml','relying-party.xml','metadata-providers.xml','saml-nameid.properties'].map(name=>`idp/shibboleth/conf/${name}.template`),
      'idp/shibboleth/metadata/sp-metadata.xml.template','apps/dotnet-shibsp/shibboleth/shibboleth2.xml.template','apps/dotnet-shibsp/Web.Demo.config.template'];
    for(const file of files) {
      mkdirSync(dirname(resolve(temporary,file)),{recursive:true});
      cpSync(resolve(root,file),resolve(temporary,file));
    }
    mkdirSync(resolve(temporary,'.local/tls'),{recursive:true});
    for(const name of ['idp-signing','drupal','student'])writeFileSync(resolve(temporary,`.local/tls/${name}.crt`),'-----BEGIN CERTIFICATE-----\nZml4dHVyZQ==\n-----END CERTIFICATE-----\n');
    execFileSync(process.execPath,[resolve(temporary,'scripts/configure.mjs')],{stdio:'pipe'});
    const metadata=readFileSync(resolve(temporary,'.local/idp-metadata.xml'),'utf8');
    assert.equal(XMLValidator.validate(metadata),true);
    const descriptor=parser.parse(metadata).EntityDescriptor;
    assert.equal(descriptor['@_xmlns:shibmd'],'urn:mace:shibboleth:metadata:1.0');
    const scope=descriptor.IDPSSODescriptor.Extensions['shibmd:Scope'];
    assert.equal(scope['@_regexp'],'false');
    assert.equal(scope['#text'],'demo.test');
    for(const user of JSON.parse(read('idp/ldap/users.json')))assert.equal(user.eduPersonPrincipalName.split('@')[1],scope['#text']);
  } finally { rmSync(temporary,{recursive:true,force:true}); }
});
