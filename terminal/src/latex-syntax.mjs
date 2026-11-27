const namedArguments = new Set([
  'begin', 'end', 'documentclass', 'usepackage', 'input', 'include', 'includegraphics',
  'bibliography', 'bibliographystyle', 'addbibresource', 'label', 'ref', 'eqref', 'pageref',
  'autoref', 'cref', 'Cref', 'cite', 'citep', 'citet', 'parencite', 'textcite',
]);
const mathControls = new Set(['\\(', '\\)', '\\[', '\\]']);

export function* latexTokens(text) {
  const pattern = /\\(?:[A-Za-z@]+|.)?|%|\${1,2}|[{}\[\]^_&#~]/gu;
  const fieldPattern = /[ \t]*(?:\[[^\[\]\r\n%]*\][ \t]*)?\{([^{}\\%\r\n]+)\}/dyu;
  let field;
  let match;

  while ((match = pattern.exec(text)) !== null) {
    const [value] = match;
    const start = match.index;
    const end = pattern.lastIndex;
    if (value === '%') {
      yield {start, end: text.length, color: 'greenBright'};
      return;
    }

    if (field?.[0] === end && value === '{') {
      yield {start, end, color: 'blueBright'};
      yield {start: end, end: field[1], color: 'yellowBright'};
      yield {start: field[1], end: field[1] + 1, color: 'blueBright'};
      pattern.lastIndex = field[1] + 1;
      field = undefined;
      continue;
    }

    if (value[0] === '\\') {
      yield {start, end, color: mathControls.has(value) ? 'magentaBright' : 'cyanBright'};
      if (value === '\\verb') {
        const delimiterIndex = end + Number(text[end] === '*');
        const codePoint = text.codePointAt(delimiterIndex);
        const delimiter = codePoint === undefined ? '' : String.fromCodePoint(codePoint);
        if (delimiter && !/\s/u.test(delimiter)) {
          const close = text.indexOf(delimiter, delimiterIndex + delimiter.length);
          const literalEnd = close < 0 ? text.length : close + delimiter.length;
          yield {start: end, end: literalEnd, color: 'yellowBright'};
          pattern.lastIndex = literalEnd;
        }
      } else if (namedArguments.has(value.slice(1))) {
        fieldPattern.lastIndex = end;
        field = fieldPattern.exec(text)?.indices[1];
      }
    } else {
      const color = '$^_&#~'.includes(value[0]) ? 'magentaBright' : 'blueBright';
      yield {start, end, color};
    }
  }
}
