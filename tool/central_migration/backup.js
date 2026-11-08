'use strict';
const backup = require('./backup_v2');
if (require.main === module) backup.main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = backup;
