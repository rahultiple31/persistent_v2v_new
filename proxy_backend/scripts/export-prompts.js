#!/usr/bin/env node
// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// One-time setup of the interpreter prompts in Parameter Store (proxy/src/services/promptStore.js).
// Writes the built-in prompts to files, one per language, and prints the AWS CLI commands that store them
// as SecureString parameters (version 1) and approve those versions. Needs no npm install: CloudShell has
// Node.js and the AWS CLI.
//
//   node proxy/scripts/export-prompts.js <SSM hierarchy, e.g. /V2V/POC/> [folder, default v2v-prompts]
//
// The commands never overwrite a prompt that exists already: put-parameter without --overwrite fails for it.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BUILT_IN_TEMPLATES, PROMPT_LANGUAGES } from "../src/prompts/builtinPrompts.js";

const [hierarchyArg, folder = "v2v-prompts"] = process.argv.slice(2);
if (!hierarchyArg || !/^\/[A-Za-z0-9_.\-/]*$/.test(hierarchyArg)) {
  console.error("Usage: node proxy/scripts/export-prompts.js <SSM hierarchy, e.g. /V2V/POC/> [folder]");
  process.exit(1);
}
const hierarchy = hierarchyArg.endsWith("/") ? hierarchyArg : `${hierarchyArg}/`;

mkdirSync(folder, { recursive: true });
for (const language of PROMPT_LANGUAGES) {
  writeFileSync(join(folder, `${language}.txt`), BUILT_IN_TEMPLATES[language], "utf8");
}
const approved = JSON.stringify(Object.fromEntries(PROMPT_LANGUAGES.map((language) => [language, 1])));

console.log(`Wrote ${PROMPT_LANGUAGES.length} prompts to ${folder}/. Run these commands in the stack's account and Region:\n`);
console.log("# 1. Store each prompt as an encrypted parameter (version 1). Add --key-id <key> for a key other than aws/ssm.");
for (const language of PROMPT_LANGUAGES) {
  console.log(
    `aws ssm put-parameter --name "${hierarchy}prompts/${language}" --type SecureString ` +
      `--value "file://${folder}/${language}.txt" --description "V2V interpreter prompt (${language})"`,
  );
}
console.log("\n# 2. Approve version 1 of each (the deploy created promptVersions as {}: built-in prompts).");
console.log(`aws ssm put-parameter --name "${hierarchy}promptVersions" --type String --overwrite --value '${approved}'`);
console.log("\nThe proxy picks the change up within 30 seconds: its log shows \"prompt version in use\" per language.");
