'use strict';
function parse(argv=process.argv.slice(2)) {
  const args={};
  for(let i=0;i<argv.length;i++) {
    if(!argv[i].startsWith('--')) throw Error(`Unexpected argument: ${argv[i]}`);
    const key=argv[i].slice(2);
    if(Object.hasOwn(args,key)) throw Error(`Duplicate argument: ${key}`);
    args[key]=argv[i+1]&&!argv[i+1].startsWith('--')?argv[++i]:true;
  }
  return args;
}
module.exports={parse};
