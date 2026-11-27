const dark = {
  muted: '#A5B3C5',
  border: '#56677C',
  focusBorder: '#7897C2',
  accent: '#AAC8F2',
  success: '#AAC9B3',
  warning: '#E5C795',
  error: '#EFADB7',
};

const light = {
  muted: '#526075',
  border: '#8592A4',
  focusBorder: '#506F9B',
  accent: '#355F96',
  success: '#35654B',
  warning: '#7B591E',
  error: '#923F50',
};

const neutral = {
  muted: '#78808E',
  border: '#647184',
  focusBorder: '#6582AB',
  accent: '#5678AA',
  success: '#508166',
  warning: '#967430',
  error: '#A95869',
};

const darkHighlights = {
  activeLine: '#222F41',
  activeItem: '#31455F',
  activeText: '#DCE5F0',
  activeAccent: '#AAC8F2',
  selection: '#3C536F',
  selectionText: '#F0F5FC',
};

const lightHighlights = {
  activeLine: '#E7EEF8',
  activeItem: '#DAE7F7',
  activeText: '#23354C',
  activeAccent: '#355F96',
  selection: '#C4D9F4',
  selectionText: '#182D49',
};

const darkSyntax = {
  cyanBright: '#A2C8EF',
  greenBright: '#9DB49C',
  yellowBright: '#E6C58B',
  magentaBright: '#CEB8EB',
  blueBright: '#A3B3D6',
};

const lightSyntax = {
  cyanBright: '#345E93',
  greenBright: '#46664C',
  yellowBright: '#79591C',
  magentaBright: '#704F93',
  blueBright: '#536889',
};

const neutralSyntax = {
  cyanBright: '#527AA9',
  greenBright: '#607F63',
  yellowBright: '#927337',
  magentaBright: '#856BA5',
  blueBright: '#74809E',
};

const ansiSyntax = {
  cyanBright: 'cyanBright',
  greenBright: 'greenBright',
  yellowBright: 'yellowBright',
  magentaBright: 'magentaBright',
  blueBright: 'white',
};

// COLORFGBG gives a useful hint when present. The workspace itself inherits the terminal background.
const background = Number.parseInt(process.env.COLORFGBG?.split(';').at(-1), 10);
const knownBackground = background >= 0 && background <= 15;
const lightBackground = knownBackground && background >= 7 && background !== 8;
const basicColor = process.stdout.getColorDepth?.() === 4;

export const palette = basicColor ? {
  muted: undefined,
  border: 'gray',
  focusBorder: 'cyan',
  accent: lightBackground ? 'blue' : 'cyan',
  success: 'green',
  warning: lightBackground ? 'red' : 'yellow',
  error: 'red',
  activeLine: 'blue',
  activeItem: 'blue',
  activeText: 'whiteBright',
  activeAccent: 'cyanBright',
  selection: 'cyan',
  selectionText: 'black',
} : {
  ...(lightBackground ? light : knownBackground ? dark : neutral),
  ...(lightBackground ? lightHighlights : darkHighlights),
};

export const activeSyntaxColors = basicColor ? ansiSyntax : lightBackground ? lightSyntax : darkSyntax;
export const syntaxColors = basicColor && lightBackground ? {
  cyanBright: 'blue',
  greenBright: 'green',
  yellowBright: 'red',
  magentaBright: 'magenta',
  blueBright: undefined,
} : basicColor || knownBackground ? activeSyntaxColors : neutralSyntax;
