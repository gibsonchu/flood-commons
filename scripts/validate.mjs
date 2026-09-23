import fs from 'node:fs';
import assert from 'node:assert/strict';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
const root=new URL('../',import.meta.url);
const ajv=new Ajv({allErrors:true,strict:false});addFormats(ajv);
const schemas=Object.fromEntries(['FRS','FMS','FSS'].map(s=>[s,ajv.compile(JSON.parse(fs.readFileSync(new URL(`standards/${s.toLowerCase()}.schema.json`,root))))]));
const examples=JSON.parse(fs.readFileSync(new URL('standards/examples.json',root)));
for(const record of examples){assert.ok(schemas[record.standard](record),JSON.stringify(schemas[record.standard].errors));}
let checks=3;
for(const r of examples){const bad=structuredClone(r);bad.editor_notes='private field';assert.equal(schemas[bad.standard](bad),false);checks++;}
const observation=structuredClone(examples.find(x=>x.standard==='FMS'));observation.media.observation=null;assert.equal(schemas.FMS(observation),false);checks++;
const wrong=structuredClone(examples[0]);wrong.schema_version='1.0.0';assert.equal(schemas.FRS(wrong),false);checks++;
const badId=structuredClone(examples[0]);badId.id='a-local-id';assert.equal(schemas.FRS(badId),false);checks++;
const badGeo=structuredClone(examples[0]);badGeo.places[0].geometry={type:'Point',coordinates:[999,91]};assert.equal(schemas.FRS(badGeo),false);checks++;
const badDate=structuredClone(examples[0]);badDate.source.checked_at='2026-02-30';assert.equal(schemas.FRS(badDate),false);checks++;
const badStatus=structuredClone(examples.find(x=>x.standard==='FSS'));badStatus.service.availability='active';assert.equal(schemas.FSS(badStatus),false);checks++;
console.log(`${checks} schema checks passed; 3 synthetic examples conform to draft 0.1.0.`);
// Optional PRIVATE pilot validation: pass a local file, never commit it to this repository.
if(process.argv[2]){const records=JSON.parse(fs.readFileSync(process.argv[2]));for(const r of records)assert.ok(schemas[r.standard](r),r.local_id+': '+JSON.stringify(schemas[r.standard].errors));console.log(`${records.length} supplied records validated.`);}
