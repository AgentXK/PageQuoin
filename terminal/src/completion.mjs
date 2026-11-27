// Keep these command and environment names aligned with the desktop catalog.
const commands = [...new Set((
  'documentclass usepackage begin end section subsection subsubsection chapter paragraph subparagraph ' +
  'title author date maketitle tableofcontents label ref pageref eqref autoref cref Cref nameref cite citep citet ' +
  'textcite parencite autocite footcite citeauthor citeyear bibliography bibliographystyle addbibresource printbibliography ' +
  'textbf textit texttt textsc textsf textsl textrm textup textnormal emph underline footnote footnotemark ' +
  'item caption captionof centering includegraphics graphicspath input include includeonly ' +
  'frac dfrac tfrac sqrt overline underline widehat widetilde operatorname mathbf mathrm mathcal mathbb ' +
  'mathsf mathit text mbox ensuremath boldsymbol left right middle limits nolimits substack ' +
  'appendix part index newcommand renewcommand providecommand DeclareMathOperator newenvironment ' +
  'renewenvironment newtheorem newcounter setcounter addtocounter setlength addtolength ' +
  'hspace vspace hfill vfill quad qquad smallskip medskip bigskip newpage clearpage pagebreak noindent ' +
  'newline linebreak raggedright raggedleft geometry href url verb LaTeX TeX ' +
  'alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa lambda mu nu xi pi varpi ' +
  'rho varrho sigma varsigma tau upsilon phi varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega ' +
  'sum prod int iint iiint oint infty partial nabla ell hbar forall exists nexists neg emptyset varnothing ' +
  'in notin ni subset subseteq supset supseteq cup cap bigcup bigcap setminus land lor ' +
  'times div cdot ast star circ bullet oplus otimes pm mp le leq ge geq ne neq equiv approx sim simeq cong propto ' +
  'to rightarrow leftarrow leftrightarrow mapsto Rightarrow Leftarrow Leftrightarrow longrightarrow longleftarrow ' +
  'uparrow downarrow hookrightarrow dots ldots cdots vdots ddots langle rangle lceil rceil lfloor rfloor ' +
  'mid parallel perp angle aleph prime dagger ddagger'
).split(' '))];

const environments = (
  'document abstract figure figure* table table* tabular tabular* tabularx longtable ' +
  'itemize enumerate description quote quotation verse center flushleft flushright ' +
  'minipage multicols equation equation* align align* aligned gather gather* multline multline* ' +
  'split cases array matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix ' +
  'theorem lemma proof definition proposition corollary example ' +
  'frame columns column block alertblock tikzpicture listing lstlisting verbatim'
).split(' ');

function isCodeAt(line, anchor) {
  const tokens = /\\(?:[A-Za-z@]+|.)?|%/gu;
  for (let match = tokens.exec(line); match; match = tokens.exec(line)) {
    if (match.index >= anchor) return true;
    const [token] = match;
    const after = match.index + token.length;
    if (token === '%' || after > anchor) return false;
    if (token !== '\\verb') continue;

    const start = after + Number(line[after] === '*');
    const code = line.codePointAt(start);
    if (code === undefined) continue;
    const delimiter = String.fromCodePoint(code);
    if (/\s/u.test(delimiter)) continue;
    const close = line.indexOf(delimiter, start + delimiter.length);
    if (close === -1 || anchor <= close) return false;
    tokens.lastIndex = close + delimiter.length;
  }
  return true;
}

export function latexCompletions(line, column) {
  if (!Number.isInteger(column) || column <= 0 || column > line.length) return null;
  const lower = Math.max(0, column - 96);
  const before = line.slice(lower, column);
  const environment = /\\(?:begin|end)[ \t]*\{([A-Za-z0-9*@-]{0,64})$/.exec(before);
  const match = environment ?? /\\([A-Za-z@]{0,64})$/.exec(before);
  if (!match) return null;
  const anchor = lower + match.index;
  if (!isCodeAt(line, anchor)) return null;

  const prefix = match[1];
  const start = environment ? column - prefix.length : anchor;
  const suffix = environment ? /[A-Za-z0-9*@-]*/y : /[A-Za-z@]*/y;
  suffix.lastIndex = column;
  suffix.exec(line);
  const end = suffix.lastIndex;
  const items = [];
  for (const name of environment ? environments : commands) {
    if (!name.startsWith(prefix)) continue;
    const text = environment ? name : '\\' + name;
    if (end === column && line.slice(start, end) === text) continue;
    items.push({label: text, text});
  }
  return items.length ? {start, end, items} : null;
}
