// jsdom does not expose `TextEncoder`/`TextDecoder` as globals, though every
// browser the booth targets has them. Node has the same implementation, so lend
// it to the test environment.
const { TextDecoder, TextEncoder } = require("node:util");

global.TextEncoder ||= TextEncoder;
global.TextDecoder ||= TextDecoder;
