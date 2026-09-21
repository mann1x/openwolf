import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { buildHookCommand } from '../utils/hook-command.js';
/** Existing local or inherited status lines remain owned by their user. */
export function withVisibilityStatusline<T extends Record<string,any>>(root:string,settings:T):T {
  if(settings.statusLine!==undefined)return settings;
  const configDir=process.env.CLAUDE_CONFIG_DIR||path.join(os.homedir(),'.claude');
  const inherited:string[]=[];for(let ancestor=path.dirname(root);;ancestor=path.dirname(ancestor)){inherited.push(path.join(ancestor,'.claude/settings.json'),path.join(ancestor,'.claude/settings.local.json'));if(path.dirname(ancestor)===ancestor)break}
  for(const file of [...inherited,path.join(configDir,'settings.json'),path.join(configDir,'settings.local.json'),path.join(root,'.claude/settings.local.json')]){
    try{if(JSON.parse(fs.readFileSync(file,'utf8')).statusLine!==undefined)return settings}catch(e){if((e as NodeJS.ErrnoException).code!=='ENOENT')return settings}
  }
  const script=path.join(root,'.wolf/hooks/visibility-statusline.js').replace(/\\/g,'/');
  // Match existing Node hook command format. No existing command is wrapped or executed.
  // Routed through the same launcher as the hooks on Windows: the status line is
  // re-rendered constantly, so it is the most visible source of console flashes,
  // and the launcher preserves the stdout Claude Code reads the line from.
  return {...settings,statusLine:{type:'command',command:buildHookCommand(script)}};
}
