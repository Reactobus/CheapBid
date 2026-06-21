// Headless test runner for CheapBids: loads the real addon under a mocked WoW API
// (Lua via fengari) and runs the spec. Usage: node tests/run.js
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib } = fengari;
const to = fengari.to_luastring;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function run(file) {
  const src = fs.readFileSync(file, 'utf8');
  if (lauxlib.luaL_loadbuffer(L, to(src), null, to('@' + path.basename(file))) !== lua.LUA_OK) {
    console.error('LOAD ERROR (' + file + '): ' + lua.lua_tojsstring(L, -1));
    process.exit(2);
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    console.error('RUNTIME ERROR (' + file + '): ' + lua.lua_tojsstring(L, -1));
    process.exit(2);
  }
}

run(path.join(__dirname, 'mocks.lua'));
run(path.join(__dirname, '..', 'CheapBids', 'CheapBids.lua'));
run(path.join(__dirname, 'spec.lua'));

lua.lua_getglobal(L, to('TEST_FAILED'));
const failed = lua.lua_tointeger(L, -1);
process.exit(failed > 0 ? 1 : 0);
