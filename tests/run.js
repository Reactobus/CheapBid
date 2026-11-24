// Headless test runner for CheapBids: loads the real addon under a mocked WoW API
// (Lua via fengari) and runs the spec. Usage: node tests/run.js
//
// Two SEPARATE Lua states:
//   1) legacy (TBC Anniversary): mocks.lua -> CheapBids.lua -> spec.lua (+ plug-in specs)
//   2) modern (WoW Forever, C_AuctionHouse): mocks.lua -> mocks_modern.lua -> Modern.lua
//      -> CheapBids.lua -> spec_modern.lua
// Exit code is non-zero when either state reports TEST_FAILED > 0.
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib } = fengari;
const to = fengari.to_luastring;

function newState() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  return L;
}

function run(L, file) {
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

function failedCount(L) {
  lua.lua_getglobal(L, to('TEST_FAILED'));
  const n = lua.lua_tointeger(L, -1);
  lua.lua_pop(L, 1);
  return n;
}

// ---- 1) legacy client ----
const L = newState();
run(L, path.join(__dirname, 'mocks.lua'));
run(L, path.join(__dirname, '..', 'CheapBids', 'CheapBids.lua'));
run(L, path.join(__dirname, 'spec.lua'));
run(L, path.join(__dirname, '..', 'CheapBids_Disenchant', 'Disenchant.lua'));
run(L, path.join(__dirname, 'spec_disenchant.lua'));
run(L, path.join(__dirname, '..', 'CheapBids_Prospect', 'Prospect.lua'));
run(L, path.join(__dirname, 'spec_prospect.lua'));
const legacyFailed = failedCount(L);

// ---- 2) modern client (C_AuctionHouse), fresh state ----
const M = newState();
run(M, path.join(__dirname, 'mocks.lua'));
run(M, path.join(__dirname, 'mocks_modern.lua'));
run(M, path.join(__dirname, '..', 'CheapBids', 'Modern.lua'));
run(M, path.join(__dirname, '..', 'CheapBids', 'CheapBids.lua'));
run(M, path.join(__dirname, 'spec_modern.lua'));
const modernFailed = failedCount(M);

process.exit(legacyFailed > 0 || modernFailed > 0 ? 1 : 0);
