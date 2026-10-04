// Test-only preload: redirect the exact OS-user API used by the owner library.
import os from "node:os";
import { syncBuiltinESMExports } from "node:module";
if (!process.env.FM_V2_TEST_SCRATCH_HOME?.startsWith("/")) throw new Error("absolute scratch home required");
const original = os.userInfo;
os.userInfo = (...args) => ({ ...original(...args), homedir: process.env.FM_V2_TEST_SCRATCH_HOME });
syncBuiltinESMExports();
