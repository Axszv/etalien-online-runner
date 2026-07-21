import fs from "node:fs";

const output = process.argv[2];
const token = process.env.ETALIEN_TOKEN || "";
const dvc = process.env.ETALIEN_DVC || "";

if (!output || !token) {
  throw new Error("output path and ETALIEN_TOKEN are required");
}

const escapeXml = (value) => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&apos;");

const dvcEntry = dvc
  ? `    <string name="CACHE_ANDROID_ID">${escapeXml(dvc)}</string>\n`
  : "";

fs.writeFileSync(output, [
  "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>",
  "<map>",
  "    <boolean name=\"AGREE_PRIVACY\" value=\"true\" />",
  `    <string name="CUR_USER_TOKEN">${escapeXml(token)}</string>`,
  dvcEntry.trimEnd(),
  "</map>",
  "",
].filter(Boolean).join("\n"), { mode: 0o600 });
