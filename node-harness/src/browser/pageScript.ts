// Fixed first-party code executed in a non-universal isolated world. Model input is
// passed as JSON arguments, never interpolated into source. No cookies/storage/network.
export const PAGE_SCRIPT = String.raw`(() => {
  if (globalThis.__piBrowser) return;
  let refs = new Map();
  const normalize = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
  const text = s => String(s || '').replace(/\s+/g,' ').trim();
  const credential = e => {
    if(!(e instanceof HTMLInputElement || e instanceof HTMLTextAreaElement || e.isContentEditable))return false;
    if(e instanceof HTMLInputElement && ['button','submit','reset','hidden','checkbox','radio','color','range','file'].includes(e.type))return false;
    if(e.type==='password' || (e.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).some(token=>['username','current-password','new-password'].includes(token)))return true;
    const labels=[name(e),e.getAttribute('aria-label'),e.getAttribute('placeholder'),e.getAttribute('title')].map(s=>normalize(s).replace(/[:* .]+$/g,''));
    const pattern=/^(?:(?:enter|please enter|your|current|new|confirm|repeat|retype|account|login|ihr|dein|aktuelles|neues)\s+)*(?:user[ _-]?name|benutzername|nutzername|anmeldename|password|passwort|kennwort)(?:\s*(?:\((?:required|optional|erforderlich)\)|required|optional|bestatigen|wiederholen|(?:or|oder|\/)\s*(?:email|e-mail|username)))?$/;
    return labels.some(s=>s.length<=160&&pattern.test(s)) || [e.id,e.getAttribute('name')].some(s=>/(?:^|[-_])(?:username|user[-_]name|password|passwd|passwort|kennwort)(?:$|[-_])/.test(normalize(s)));
  };
  const editable = e => (e instanceof HTMLInputElement && ['text','search','email','url','tel','number','password'].includes(e.type)) || e instanceof HTMLTextAreaElement || e.isContentEditable;
  const role = e => e.getAttribute('role') || ({BUTTON:'button',A:e.hasAttribute('href')?'link':'',TEXTAREA:'textbox',SELECT:'combobox',SUMMARY:'button'}[e.tagName]) || (e.tagName==='INPUT' ? ({checkbox:'checkbox',radio:'radio',button:'button',submit:'button',reset:'button'}[e.type] || 'textbox') : e.isContentEditable?'textbox':'');
  const name = e => {
    const labelled = (e.getAttribute('aria-labelledby') || '').split(/\s+/).slice(0,8).map(id => document.getElementById(id)?.textContent || '').join(' ');
    return text(e.getAttribute('aria-label') || labelled || (e.labels && Array.from(e.labels).map(x=>x.textContent).join(' ')) || (['INPUT','TEXTAREA','SELECT'].includes(e.tagName) ? (e.getAttribute('placeholder') || e.getAttribute('title') || (['button','submit','reset'].includes(e.type)?e.value:'')) : e.innerText || e.getAttribute('alt') || e.getAttribute('title')));
  };
  const visible = e => {
    const s=getComputedStyle(e), r=e.getBoundingClientRect();
    return s.display!=='none' && s.visibility==='visible' && Number(s.opacity)!==0 && r.width>0 && r.height>0 && !e.closest('[hidden],[inert],[aria-hidden="true"]');
  };
  const disabled = e => e.matches(':disabled') || e.getAttribute('aria-disabled')==='true' || e.closest('[inert]');
  const fingerprint = e => {
    const container=e.closest('article,[role=article],li,[role=listitem],tr,[role=row],dialog,[role=dialog],form') || e.parentElement;
    // Context identifies e.g. the post around an otherwise identical Like button.
    // A changed/virtualized item invalidates the reference rather than hitting its successor.
    const context=text(container?.innerText);
    return JSON.stringify([e.tagName,e.type || '',role(e),name(e),e.getAttribute('href'),e.getAttribute('target'),e.getAttribute('id'),context]);
  };
  const destructive = e => {
    const labels=[name(e),e.getAttribute('title'),e.getAttribute('aria-label')].map(normalize);
    const ids=normalize([e.id,e.getAttribute('data-testid'),e.getAttribute('data-action')].join(' '));
    return labels.some(s => /^(delete(?: permanently| file(?:s)?| selected files)?|permanently delete|move to (?:trash|bin)|empty (?:trash|bin)|remove files?|loschen|datei(?:en)? loschen|endgultig loschen|sofort loschen|in den papierkorb (?:legen|verschieben)|papierkorb leeren)[.!…]*$/.test(s)) || /delete[-_]?file|delete[-_]selected|move[-_]to[-_]trash|empty[-_]trash|trash[-_]selection|remove[-_]file/.test(ids);
  };
  const eligibleLink = e => {
    const a=e.closest('a[href]'); if(!a)return true;
    let u; try{u=new URL(a.href,location.href)}catch{return false}
    return ['https:','http:'].includes(u.protocol) && !u.username && !u.password && !a.hasAttribute('download') && (!a.target || a.target==='_self');
  };
  const hit = e => {
    const r=e.getBoundingClientRect();
    const cx=(Math.max(0,r.left)+Math.min(r.right,innerWidth))/2,cy=(Math.max(0,r.top)+Math.min(r.bottom,innerHeight))/2;
    if(cx<0||cy<0||cx>=innerWidth||cy>=innerHeight||r.bottom<=0||r.right<=0||r.left>=innerWidth||r.top>=innerHeight)return false;
    const top=e.getRootNode().elementFromPoint?.(cx,cy) || document.elementFromPoint(cx,cy);
    return top===e || e.contains(top);
  };
  function snapshot(filter,prefix,allowCredentialFields=false) {
    refs.clear(); let lines=[], chars=0, count=0, truncated=false, visited=0;
    const add=s=>{ if(chars+s.length>24000){truncated=true;return false}lines.push(s);chars+=s.length;return true };
    const root=document.scrollingElement;
    if(root){refs.set(prefix+'page',{e:root,doc:document,stamp:'page',page:true});add('['+prefix+'page] page (scroll only)')}
    const visit=(node,depth)=>{
      if(++visited>8000 || depth>40 || count>=300 || chars>=24000){truncated=true;return}
      if(node.nodeType===3){const s=text(node.textContent);if(s&&(!filter||s.toLowerCase().includes(filter)))add(s.slice(0,2000));return}
      if(!(node instanceof Element))return;
      if(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS'].includes(node.tagName)||!visible(node))return;
      if(node.tagName==='IFRAME'){add('[iframe: not exposed by this browser adapter]');return}
      const r=role(node),n=name(node);
      if(r && ['button','link','textbox','checkbox','radio','combobox','switch','tab','menuitem'].includes(r)){
        if(!filter||n.toLowerCase().includes(filter)||text(node.closest('article,li,tr,form')?.innerText).toLowerCase().includes(filter)){
          const isCredential=credential(node);
          const id=prefix+(++count),stamp=fingerprint(node);
          if(stamp.length>16000){add('[element context exceeds safety limit]');return}
          const line='['+id+'] '+r+' '+JSON.stringify(n.slice(0,512))+(isCredential?' [credential field; value omitted; input '+(allowCredentialFields===true?'allowed':'blocked in pi-os Settings')+']':'')+(disabled(node)?' disabled':'')+(node.getAttribute('aria-pressed')!==null?' pressed='+node.getAttribute('aria-pressed'):'')+('checked' in node?' checked='+node.checked:'');
          if(add(line))refs.set(id,{e:node,doc:document,stamp,page:false});
        }
        if(['INPUT','TEXTAREA','SELECT','BUTTON','A'].includes(node.tagName)||node.isContentEditable)return;
      }
      if(node.shadowRoot) for(const child of node.shadowRoot.childNodes){if(visited>=8000)break;visit(child,depth+1)}
      for(const child of node.childNodes){if(visited>=8000)break;visit(child,depth+1)}
    };
    if(document.body)visit(document.body,0);
    return {text:lines.join('\n'),truncated,refCount:refs.size};
  }
  const CONTROLS=['button','link','textbox','checkbox','radio','combobox','switch','tab','menuitem'];
  const inView = r => r.bottom>0 && r.right>0 && r.top<innerHeight && r.left<innerWidth;
  const textRect = node => { try { const range=document.createRange(); range.selectNodeContents(node); return range.getBoundingClientRect(); } catch { return node.parentElement.getBoundingClientRect(); } };
  // Voice/act fast path: controls only (plus a little visible text), viewport first, at most
  // 100 lines and 60-char names. Same traversal, visibility and credential rules as snapshot().
  // Controls sharing role and name (several "Like" buttons, liked or not) collapse into one
  // line WITHOUT a ref: lacking their surrounding post, a compact view could aim at the wrong one.
  function snapshotCompact(prefix,allowCredentialFields=false) {
    refs.clear(); const inside=[], outside=[], seen=[]; let visited=0, seenChars=0, truncated=false, frames=0;
    const root=document.scrollingElement;
    if(root)refs.set(prefix+'page',{e:root,doc:document,stamp:'page',page:true});
    const state=e=>(credential(e)?' [credential field; value omitted; input '+(allowCredentialFields===true?'allowed':'blocked in pi-os Settings')+']':'')+(disabled(e)?' disabled':'')+(e.getAttribute('aria-pressed')!==null?' pressed='+e.getAttribute('aria-pressed'):'')+('checked' in e?' checked='+e.checked:'');
    const visit=(node,depth)=>{
      // Off-view controls have their own cap, so a long page scrolled far down still reaches
      // the controls in view.
      if(++visited>8000 || depth>40 || inside.length>=400){truncated=true;return}
      if(node.nodeType===3){
        if(seenChars>=1200||!node.parentElement)return;
        const s=text(node.textContent);
        if(s&&inView(textRect(node))){const t=s.slice(0,160);seen.push(t);seenChars+=t.length}
        return;
      }
      if(!(node instanceof Element))return;
      if(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS'].includes(node.tagName)||!visible(node))return;
      if(node.tagName==='IFRAME'){frames++;return}
      const r=role(node);
      if(r && CONTROLS.includes(r)){
        const box=node.getBoundingClientRect(), item={e:node,r,n:name(node),view:inView(box),above:box.bottom<=0};
        if(item.view)inside.push(item); else if(outside.length<400)outside.push(item); else truncated=true;
        if(['INPUT','TEXTAREA','SELECT','BUTTON','A'].includes(node.tagName)||node.isContentEditable)return;
      }
      if(node.shadowRoot) for(const child of node.shadowRoot.childNodes){if(visited>=8000)break;visit(child,depth+1)}
      for(const child of node.childNodes){if(visited>=8000)break;visit(child,depth+1)}
    };
    if(document.body)visit(document.body,0);
    const groups=new Map();
    for(const item of [...inside,...outside]){
      const n=item.n.length>60?item.n.slice(0,59)+'…':item.n, label=item.r+' '+JSON.stringify(n);
      const group=groups.get(label);
      if(group)group.push(item);
      else groups.set(label,[item]);
    }
    const lines=root?['['+prefix+'page] page (scroll only)']:[]; let count=0, kept=0;
    for(const [label,items] of groups){
      if(kept>=100){truncated=true;break}
      kept++;
      const item=items[0], where=item.view?'':item.above?' (above view)':' (below view)';
      if(items.length>1){
        const states=new Map();
        for(const other of items){const s=state(other.e).trim();if(s)states.set(s,(states.get(s)||0)+1)}
        const summary=states.size?' ('+[...states].map(([s,n])=>s+' ×'+n).join(', ')+')':'';
        lines.push('- '+label+' ×'+items.length+where+summary+' (same role and name; no ref: use browser_snapshot with a filter to choose one)');
        continue;
      }
      const stamp=fingerprint(item.e);
      if(stamp.length>16000){lines.push('- '+label+state(item.e)+where+' (element context exceeds safety limit)');continue}
      const id=prefix+(++count);
      refs.set(id,{e:item.e,doc:document,stamp,page:false});
      lines.push('['+id+'] '+label+state(item.e)+where);
    }
    if(frames)lines.push('- '+frames+' frame(s) not exposed by this browser adapter');
    if(seen.length)lines.push('Visible text: '+seen.join(' | ').slice(0,1200));
    return {text:lines.join('\n'),truncated,refCount:refs.size};
  }
  // Resolve after two animation frames and minMs, or at maxMs (≤ 200), whichever first.
  function settle(minMs,maxMs) {
    const cap=Math.max(0,Math.min(200,Number(maxMs)||0)), floor=Math.max(0,Math.min(cap,Number(minMs)||0));
    return new Promise(resolve=>{
      let frames=false, waited=false, done=false;
      const finish=()=>{if(!done){done=true;resolve(true)}};
      const check=()=>{if(frames&&waited)finish()};
      setTimeout(()=>{waited=true;check()},floor); setTimeout(finish,cap);
      try{requestAnimationFrame(()=>requestAnimationFrame(()=>{frames=true;check()}))}catch{frames=true;check()}
    });
  }
  function inspect(id,action,key,allowCredentialFields=false,inputText='') {
    if(document.visibilityState!=='visible')return {error:'browser_target_changed'};
    const ref=refs.get(id);
    if(!ref||ref.doc!==document||!ref.e.isConnected)return {error:'browser_stale'};
    const e=ref.e;
    if(ref.page)return action==='scroll'?{ok:true}:{error:'browser_unsupported_action'};
    if(!visible(e)||disabled(e)||fingerprint(e)!==ref.stamp)return {error:'browser_stale'};
    if(action!=='scroll'&&credential(e)&&allowCredentialFields!==true)return {error:'credential_input_blocked'};
    if((action==='click'||action==='press'&&['Enter','Space'].includes(key))&&destructive(e))return {error:'file_deletion_blocked'};
    if((action==='click'||action==='press'&&['Enter','Space'].includes(key))&&!eligibleLink(e))return {error:'browser_unsupported_link'};
    if(action==='fill'&&!editable(e))return {error:'browser_unsupported_action'};
    if(action==='press'&&['Backspace','Delete'].includes(key)&&!editable(e))return {error:'file_deletion_blocked'};
    if(action==='press'&&!editable(e)&&!['button','checkbox','radio','switch','link','menuitem','tab','combobox'].includes(role(e)))return {error:'browser_unsupported_action'};
    if(action!=='scroll'&&!hit(e))return {error:'browser_occluded'};
    if(action==='fill' && (e.readOnly || (/[\r\n]/.test(inputText) && e.tagName!=='TEXTAREA' && !e.isContentEditable)))return {error:'browser_unsupported_action'};
    // A terminal/editor brand is not a typing ban. Reject recognized deletion
    // commands on terminal receivers instead; opaque scripts are not sandboxed.
    if(action==='fill' && e.closest('.xterm,[data-terminal]') && /(?:^|[;&|\u0060(\n])\s*(?:(?:sudo|command)\s+)*(?:[\w/.-]*\/)?(?:rm|rmdir|unlink|trash|remove-item|del|erase)(?:\s|$)|\bfind\b[^\n]*\s-delete\b|\b(?:shutil\s*\.\s*rmtree|os\s*\.\s*(?:remove|unlink|rmdir)|fs\s*\.\s*(?:unlink|rm|rmdir)(?:Sync)?)\s*\(/im.test(inputText))return {error:'file_deletion_blocked'};
    return {ok:true};
  }
  function act(id,action,key,dy,allowCredentialFields=false,inputText='') {
    const checked=inspect(id,action,key,allowCredentialFields,inputText); if(!checked.ok)return checked;
    const e=refs.get(id).e;
    if(action==='click') { if(typeof e.click!=='function')return {error:'browser_unsupported_action'}; HTMLElement.prototype.click.call(e); }
    if(action==='fill'||action==='press'){
      e.focus({preventScroll:true});
      if((e.getRootNode().activeElement||document.activeElement)!==e)return {error:'browser_focus_failed'};
      if(action==='fill'){
        if(e.isContentEditable){const r=document.createRange();r.selectNodeContents(e);const s=getSelection();s.removeAllRanges();s.addRange(r)}
        else if(typeof e.select==='function')e.select();else return {error:'browser_unsupported_action'};
      }
    }
    if(action==='scroll')e.scrollBy({top:dy,behavior:'instant'});
    return {ok:true};
  }
  function verifyFill(id,expected,allowCredentialFields=false){const e=refs.get(id)?.e;if(!e||!e.isConnected||(credential(e)&&allowCredentialFields!==true))return false;return (e.isContentEditable?e.textContent:e.value)===expected}
  globalThis.__piBrowser={snapshot,snapshotCompact,settle,inspect,act,verifyFill,clear:()=>refs.clear()};
})()`;
