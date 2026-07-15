#!/usr/bin/env node

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const runtimeSource = readFileSync(join(repoRoot, 'src', 'runtime', 'bridge_responses.zig'), 'utf8');
const runtimeFlowSource = readFileSync(join(repoRoot, 'src', 'runtime', 'flow.zig'), 'utf8');
const runtimeBridgePayloadSource = readFileSync(join(repoRoot, 'src', 'runtime', 'bridge_payload.zig'), 'utf8');
const platformSource = readFileSync(join(repoRoot, 'src', 'platform', 'types.zig'), 'utf8');
const typeSource = readFileSync(join(projectRoot, 'native-sdk.d.ts'), 'utf8');

const errors = [];

function addError(message) {
  errors.push(message);
}

function sliceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  if (start === -1) {
    addError(`missing marker: ${startMarker}`);
    return '';
  }

  const end = source.indexOf(endMarker, start);
  if (end === -1) {
    addError(`missing marker: ${endMarker}`);
    return '';
  }

  return source.slice(start, end);
}

function unique(values) {
  return [...new Set(values)];
}

function publicViewJsonKeys() {
  const body = sliceBetween(runtimeSource, 'fn writeViewJsonToWriter', 'fn writeOptionalRectJson');
  return unique([...body.matchAll(/\\\"([A-Za-z][A-Za-z0-9]*)\\\"/g)].map((match) => match[1]));
}

function viewInfoTypeBody() {
  return sliceBetween(typeSource, 'export interface NativeSdkViewInfo', 'export type NativeSdkNativeViewKind');
}

function interfaceHasProperty(body, key) {
  return new RegExp(`\\n\\s*${key}[?:]?\\s*:`).test(body);
}

function platformCursorTags() {
  const body = sliceBetween(platformSource, 'pub const Cursor = enum {', '};');
  return body
    .split('\n')
    .map((line) => line.trim().replace(/,$/, ''))
    .filter((line) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(line));
}

function platformEnumTags(enumName) {
  const declaration = `pub const ${enumName} = enum`;
  const declarationStart = platformSource.indexOf(declaration);
  if (declarationStart === -1) {
    addError(`missing enum: ${enumName}`);
    return [];
  }
  const bodyStart = platformSource.indexOf('{', declarationStart + declaration.length);
  const bodyEnd = platformSource.indexOf('};', bodyStart);
  if (bodyStart === -1 || bodyEnd === -1) {
    addError(`malformed enum: ${enumName}`);
    return [];
  }
  const body = platformSource.slice(bodyStart + 1, bodyEnd);
  return body
    .split('\n')
    .map((line) => line.trim().replace(/,$/, ''))
    .filter((line) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(line));
}

function interfaceBody(interfaceName) {
  const startMarker = `export interface ${interfaceName}`;
  const start = typeSource.indexOf(startMarker);
  if (start === -1) {
    addError(`missing interface: ${interfaceName}`);
    return '';
  }
  const bodyStart = typeSource.indexOf('{', start + startMarker.length);
  const bodyEnd = typeSource.indexOf('\n}', bodyStart);
  if (bodyStart === -1 || bodyEnd === -1) {
    addError(`malformed interface: ${interfaceName}`);
    return '';
  }
  return typeSource.slice(bodyStart + 1, bodyEnd);
}

function interfaceProperties(body) {
  return [...body.matchAll(/^\s*([A-Za-z][A-Za-z0-9]*)(\?)?\s*:\s*([^;]+);/gm)].map((match) => ({
    name: match[1],
    optional: match[2] === '?',
    type: match[3].trim(),
  }));
}

function compareExactTags(contractName, expected, actual) {
  for (const tag of expected) {
    if (!actual.includes(tag)) addError(`${contractName} is missing "${tag}"`);
  }
  for (const tag of actual) {
    if (!expected.includes(tag)) addError(`${contractName} includes unknown "${tag}"`);
  }
}

function platformFeatureAliases() {
  const body = sliceBetween(runtimeBridgePayloadSource, 'pub fn platformFeatureFromString', 'pub fn viewFrameFromJson');
  return [...body.matchAll(/std\.mem\.eql\(u8, value, "([A-Za-z][A-Za-z0-9]*)"\)\) return \.([a-z][a-z0-9_]*)/g)]
    .map((match) => ({ alias: match[1], feature: match[2] }));
}

function webViewNavigationJsonKeys() {
  const body = sliceBetween(runtimeFlowSource, 'fn emitWebViewNavigationEvent', 'try emitWindowEvent(self, navigation.window_id, "webview:navigation"');
  return unique([...body.matchAll(/\\"([A-Za-z][A-Za-z0-9]*)\\"/g)].map((match) => match[1]));
}

function typeUnionTags(typeName) {
  const match = typeSource.match(new RegExp(`export type ${typeName}\\s*=\\s*([^;]+);`));
  if (!match) {
    addError(`missing type union: ${typeName}`);
    return [];
  }

  return [...match[1].matchAll(/"([^"]+)"/g)].map((tag) => tag[1]);
}

const viewInfoBody = viewInfoTypeBody();
for (const key of publicViewJsonKeys()) {
  if (!interfaceHasProperty(viewInfoBody, key)) {
    addError(`NativeSdkViewInfo is missing runtime field "${key}"`);
  }
}

const cursorTags = platformCursorTags();
const typeCursorTags = typeUnionTags('NativeSdkCursor');
for (const tag of cursorTags) {
  if (!typeCursorTags.includes(tag)) {
    addError(`NativeSdkCursor is missing platform cursor "${tag}"`);
  }
}
for (const tag of typeCursorTags) {
  if (!cursorTags.includes(tag)) {
    addError(`NativeSdkCursor includes unknown platform cursor "${tag}"`);
  }
}

const profileRiskTags = platformEnumTags('CanvasFrameProfileRisk');
const typeProfileRiskTags = typeUnionTags('NativeSdkCanvasFrameProfileRisk');
for (const tag of profileRiskTags) {
  if (!typeProfileRiskTags.includes(tag)) {
    addError(`NativeSdkCanvasFrameProfileRisk is missing platform risk "${tag}"`);
  }
}
for (const tag of typeProfileRiskTags) {
  if (!profileRiskTags.includes(tag)) {
    addError(`NativeSdkCanvasFrameProfileRisk includes unknown platform risk "${tag}"`);
  }
}

const navigationPhaseTags = platformEnumTags('WebViewNavigationPhase');
const typeNavigationPhaseTags = typeUnionTags('NativeSdkWebViewNavigationPhase');
compareExactTags('NativeSdkWebViewNavigationPhase', navigationPhaseTags, typeNavigationPhaseTags);

const navigationFailureTags = platformEnumTags('WebViewNavigationFailureClass');
const typeNavigationFailureTags = typeUnionTags('NativeSdkWebViewNavigationFailureClass');
compareExactTags('NativeSdkWebViewNavigationFailureClass', navigationFailureTags, typeNavigationFailureTags);

const navigationDetailProperties = interfaceProperties(interfaceBody('NativeSdkWebViewNavigationDetail'));
const navigationDetailKeys = navigationDetailProperties.map((property) => property.name);
compareExactTags('NativeSdkWebViewNavigationDetail', webViewNavigationJsonKeys(), navigationDetailKeys);
const navigationDetailContract = new Map(navigationDetailProperties.map((property) => [property.name, property]));
for (const [name, expectedType, optional] of [
  ['windowId', 'number', false],
  ['label', 'string', false],
  ['navigationId', 'string', false],
  ['phase', 'NativeSdkWebViewNavigationPhase', false],
  ['url', 'string', false],
  ['failureClass', 'NativeSdkWebViewNavigationFailureClass', true],
]) {
  const property = navigationDetailContract.get(name);
  if (property && (property.type !== expectedType || property.optional !== optional)) {
    addError(`NativeSdkWebViewNavigationDetail.${name} must be ${optional ? 'optional ' : ''}${expectedType}`);
  }
}

const platformFeatureTags = platformEnumTags('PlatformFeature');
const featureAliases = platformFeatureAliases();
for (const { alias, feature } of featureAliases) {
  if (!platformFeatureTags.includes(feature)) addError(`platform feature alias "${alias}" targets unknown feature "${feature}"`);
}
for (const feature of platformFeatureTags.filter((tag) => tag.includes('_'))) {
  if (!featureAliases.some((entry) => entry.feature === feature)) {
    addError(`platform feature "${feature}" is missing a JavaScript alias`);
  }
}
const expectedPlatformFeatureTags = unique([...platformFeatureTags, ...featureAliases.map((entry) => entry.alias)]);
compareExactTags('NativeSdkPlatformFeature', expectedPlatformFeatureTags, typeUnionTags('NativeSdkPlatformFeature'));

if (errors.length > 0) {
  console.error('Runtime TypeScript contract check failed.');
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}

console.log('Runtime TypeScript contract is in sync.');
