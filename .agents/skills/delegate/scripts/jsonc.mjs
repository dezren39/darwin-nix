// JSONC used by OpenCode: comments and trailing commas, but never inside a
// string. A regex-only comma pass corrupts e.g. "literal,}" in a config value.
export function parseJsonc(source) {
  let clean = "";
  let quoted = false;
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    const next = source[i + 1];
    if (quoted) {
      clean += c;
      if (c === "\\") clean += source[++i] ?? "";
      else if (c === '"') quoted = false;
    } else if (c === '"') {
      quoted = true;
      clean += c;
    } else if (c === "/" && next === "/") {
      while (i < source.length && source[i] !== "\n") i++;
      clean += "\n";
    } else if (c === "/" && next === "*") {
      let closed = false;
      // A separating space keeps `1/*comment*/2` invalid rather than
      // silently interpreting two tokens as 12.
      clean += " ";
      i += 2;
      for (; i < source.length; i++) {
        if (source[i] === "*" && source[i + 1] === "/") {
          closed = true;
          i++;
          break;
        }
        if (source[i] === "\n") clean += "\n";
      }
      if (!closed) throw new SyntaxError("Unterminated JSONC block comment");
    } else {
      clean += c;
    }
  }
  let json = "";
  quoted = false;
  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (quoted) {
      json += c;
      if (c === "\\") json += clean[++i] ?? "";
      else if (c === '"') quoted = false;
    } else if (c === '"') {
      quoted = true;
      json += c;
    } else if (c === ",") {
      let j = i + 1;
      while (/\s/.test(clean[j] ?? "") && j < clean.length) j++;
      if (clean[j] !== "}" && clean[j] !== "]") json += c;
    } else {
      json += c;
    }
  }
  return JSON.parse(json);
}
