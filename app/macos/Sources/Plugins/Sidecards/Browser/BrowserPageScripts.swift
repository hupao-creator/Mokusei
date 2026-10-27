import Foundation

/// Only selection and inert decoration run in the selected webpage, in an isolated
/// WebKit world. All application controls and annotation editing are native.
enum BrowserPageScripts {
    static let selection = #"""

(() => {
  globalThis.__mokuseiAnnotationCancel?.();
  return new Promise(resolve => {
    const host=document.createElement('div');host.setAttribute('popover','manual');
    host.style.cssText='position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;border:0!important;background:transparent!important;overflow:hidden!important;z-index:2147483647!important';
    const root=host.attachShadow({mode:'closed'}),styles=new CSSStyleSheet();
    styles.replaceSync('.glass{position:fixed;inset:0;cursor:none;touch-action:none}.point{position:fixed;box-sizing:border-box;width:12px;height:12px;border:1.5px solid white;border-radius:50%;background:#555;box-shadow:0 0 0 .75px #5558;transform:translate(-50%,-50%);pointer-events:none;animation:point-breathe 2s ease-in-out infinite}.point[hidden]{animation:none}@keyframes point-breathe{0%,100%{transform:translate(-50%,-50%) scale(1);opacity:.92}50%{transform:translate(-50%,-50%) scale(1.12);opacity:1}}.cursor{position:fixed;width:20px;height:20px;transform:translate(-50%,-50%);pointer-events:none;overflow:visible}.cursor path{fill:none;stroke-linecap:round}.cursor .halo{stroke:white;stroke-width:3}.cursor .ink{stroke:#444;stroke-width:1}.box{position:fixed;pointer-events:none}.box svg{display:block;width:100%;height:100%;overflow:visible}.box rect{fill:none;stroke:#808080;stroke-width:2;stroke-linecap:round;stroke-dasharray:1 6;animation:region-flow 1.6s linear infinite}.box[hidden] rect{animation-play-state:paused}@keyframes region-flow{to{stroke-dashoffset:-28}}.hint{position:fixed;top:12px;left:12px;background:#202124;color:white;border-radius:8px;padding:8px 12px;font:12px system-ui;pointer-events:none}');
    root.adoptedStyleSheets=[styles];
    const glass=document.createElement('div'),box=document.createElement('div'),hint=document.createElement('div');glass.className='glass';box.className='box';box.hidden=true;hint.className='hint';hint.textContent=matchMedia('(pointer:coarse)').matches?'轻点元素或拖动框选 · 再点批注按钮取消':'点击元素或拖拽框选 · Esc 取消';
    const svg=document.createElementNS('http://www.w3.org/2000/svg','svg'),line=document.createElementNS('http://www.w3.org/2000/svg','rect');
    svg.setAttribute('aria-hidden','true');line.setAttribute('x','1');line.setAttribute('y','1');line.setAttribute('rx','2');svg.append(line);box.append(svg);const point=document.createElement('div');point.className='point';point.hidden=true;
    const cursor=document.createElementNS('http://www.w3.org/2000/svg','svg');cursor.classList.add('cursor');cursor.style.display='none';cursor.setAttribute('viewBox','0 0 20 20');cursor.setAttribute('aria-hidden','true');
    for(const name of ['halo','ink']){const path=document.createElementNS('http://www.w3.org/2000/svg','path');path.setAttribute('d','M10 1v4 M10 15v4 M1 10h4 M15 10h4');path.setAttribute('class',name);cursor.append(path);}
    root.append(glass,box,point,cursor,hint);document.documentElement.append(host);host.showPopover();
    let start,selection,target,clickPoint,pointOffset,selected=false,region=false,capturing=false,close;
    globalThis.__mokuseiAnnotationClosed=new Promise(done=>{close=done;});
    const cancel=()=>{host.remove();window.removeEventListener('keydown',key,true);window.removeEventListener('resize',resize);window.removeEventListener('pagehide',cancel);window.removeEventListener('blur',hideCursor);visualViewport?.removeEventListener('resize',resize);visualViewport?.removeEventListener('scroll',resize);close(null);if(!selected)resolve(null);delete globalThis.__mokuseiAnnotationCancel;delete globalThis.__mokuseiAnnotationRead;delete globalThis.__mokuseiAnnotationCapture;delete globalThis.__mokuseiAnnotationClosed;};
    const key=e=>{if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();cancel();}};
    const resize=()=>{if(!selected)cancel();else read();};
    const hideCursor=()=>{cursor.style.display='none';};
    const moveCursor=e=>{if(selected||capturing){hideCursor();return;}cursor.style.display='block';cursor.style.left=e.clientX+'px';cursor.style.top=e.clientY+'px';};
    glass.addEventListener('pointerenter',moveCursor);glass.addEventListener('pointerleave',hideCursor);window.addEventListener('blur',hideCursor);
    window.addEventListener('keydown',key,true);window.addEventListener('resize',resize);window.addEventListener('pagehide',cancel);visualViewport?.addEventListener('resize',resize);visualViewport?.addEventListener('scroll',resize);
    const rect=r=>({x:Math.max(0,Math.min(r.x,innerWidth-1)),y:Math.max(0,Math.min(r.y,innerHeight-1)),width:Math.max(1,Math.min(r.right,innerWidth)-Math.max(0,r.x)),height:Math.max(1,Math.min(r.bottom,innerHeight)-Math.max(0,r.y))});
    const guide=r=>{box.hidden=false;Object.assign(box.style,{left:r.x+'px',top:r.y+'px',width:r.width+'px',height:r.height+'px'});line.setAttribute('width',String(Math.max(0,r.width-2)));line.setAttribute('height',String(Math.max(0,r.height-2)));};
    const locate=el=>{const parts=[];while(el&&el.nodeType===1&&parts.length<7){if(el.id){parts.unshift('#'+CSS.escape(el.id));break;}const name=el.localName;let index=1,prev=el.previousElementSibling;while(prev){if(prev.localName===name)index++;prev=prev.previousElementSibling;}parts.unshift(name+':nth-of-type('+index+')');el=el.parentElement;}return parts.join(' > ').slice(0,4096);};
    const select=(x,y)=>{host.style.setProperty('pointer-events','none','important');let el=document.elementFromPoint(x,y);while(el?.shadowRoot?.elementFromPoint(x,y)&&el.shadowRoot.elementFromPoint(x,y)!==el)el=el.shadowRoot.elementFromPoint(x,y);host.style.removeProperty('pointer-events');target=el;if(!el)return null;const inaccessible=['iframe','canvas','object','embed'].includes(el.localName);return {kind:inaccessible?'region':'element',rect:rect(el.getBoundingClientRect()),...(!inaccessible?{selector:locate(el),text:(el.innerText||el.getAttribute('aria-label')||el.textContent||'').slice(0,4000)}:{})};};
    // Native snapshots contain the visual viewport. Keep DOM hit testing and
    // decoration in layout CSS coordinates, then normalize only the payload.
    // Account for viewport scaling without changing the wire schema.
    const visibleSelection=value=>{const v=visualViewport,ox=v?.offsetLeft||0,oy=v?.offsetTop||0,width=v?.width||innerWidth,height=v?.height||innerHeight,r=value.rect,x=Math.max(0,Math.min(r.x-ox,width-1)),y=Math.max(0,Math.min(r.y-oy,height-1));return {...value,rect:{x,y,width:Math.max(1,Math.min(r.x+r.width-ox,width)-x),height:Math.max(1,Math.min(r.y+r.height-oy,height)-y)},viewport:{width,height,scrollX:scrollX+ox,scrollY:scrollY+oy}};};
    const read=()=>{if(!selection)return null;if(!region&&target?.isConnected)selection.rect=rect(target.getBoundingClientRect());else {const r=selection.rect;selection.rect=rect({x:r.x,y:r.y,right:r.x+r.width,bottom:r.y+r.height});}if(region&&!capturing)guide(selection.rect);if(!region&&selected&&!capturing&&clickPoint){if(pointOffset&&target?.isConnected){clickPoint={x:selection.rect.x+Math.min(pointOffset.x,selection.rect.width-1),y:selection.rect.y+Math.min(pointOffset.y,selection.rect.height-1)};}point.hidden=false;point.style.left=clickPoint.x+'px';point.style.top=clickPoint.y+'px';}return visibleSelection(selection);};
    globalThis.__mokuseiAnnotationCancel=cancel;globalThis.__mokuseiAnnotationRead=read;
    // WebKit pauses animation frames for occluded content. The native capture
    // uses afterScreenUpdates to flush these mutations before taking its image.
    globalThis.__mokuseiAnnotationCapture=value=>{capturing=value;box.hidden=true;point.hidden=true;hideCursor();if(!value)read();};
    glass.addEventListener('pointerdown',e=>{if(selected||e.button!==0)return;e.preventDefault();e.stopPropagation();start={x:e.clientX,y:e.clientY};glass.setPointerCapture(e.pointerId);selection=select(start.x,start.y);region=false;box.hidden=true;point.hidden=true;moveCursor(e);});
    glass.addEventListener('pointermove',e=>{moveCursor(e);if(selected)return;e.preventDefault();if(!start)return;if(Math.hypot(e.clientX-start.x,e.clientY-start.y)>5){const x=Math.min(start.x,e.clientX),y=Math.min(start.y,e.clientY);selection={kind:'region',rect:rect({x,y,right:Math.max(start.x,e.clientX),bottom:Math.max(start.y,e.clientY)})};region=true;guide(selection.rect);}else{selection=select(start.x,start.y);region=false;box.hidden=true;}});
    glass.addEventListener('pointerup',e=>{e.preventDefault();e.stopPropagation();if(selected||!start||!selection)return;clickPoint={x:e.clientX,y:e.clientY};pointOffset={x:Math.max(0,clickPoint.x-selection.rect.x),y:Math.max(0,clickPoint.y-selection.rect.y)};start=null;selected=true;hint.hidden=true;hideCursor();glass.style.cursor='default';if(glass.hasPointerCapture(e.pointerId))glass.releasePointerCapture(e.pointerId);resolve(read());});
    glass.addEventListener('pointercancel',e=>{if(!selected){start=null;selection=null;region=false;box.hidden=true;point.hidden=true;}if(glass.hasPointerCapture(e.pointerId))glass.releasePointerCapture(e.pointerId);hideCursor();});
    for(const type of ['click','dblclick','contextmenu','wheel'])glass.addEventListener(type,e=>{e.preventDefault();e.stopPropagation();},{passive:false});
  });
})()

"""#
}

extension BrowserPageScripts {
    static let scrollbar = #"""
(() => { const style=document.createElement('style'); style.textContent='*{scrollbar-width:auto!important;scrollbar-color:auto!important}::-webkit-scrollbar{width:2px!important;height:2px!important}::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent!important}::-webkit-scrollbar-thumb{background:transparent!important;border-radius:999px!important}::-webkit-scrollbar-thumb:hover{background:rgb(128 128 128 / .35)!important}'; (document.head||document.documentElement).append(style); })();
"""#

    // WebKit exposes native media denial; remaining permission surfaces either
    // are unavailable in WKWebView or are explicitly denied at document start.
    // This script is installed for every frame and exposes no host capability.
    static let permissionDenial = #"""
(() => {
 const denied=()=>Promise.reject(new DOMException('Permission denied','NotAllowedError'));
 const install=(object,name,value)=>{const chain=[];for(let owner=object;owner&&owner!==Object.prototype;owner=Object.getPrototypeOf(owner))if(owner===object||Object.hasOwn(owner,name))chain.push(owner);for(const owner of chain){try{Object.defineProperty(owner,name,{value,writable:false,configurable:false});}catch{}}};
 if(navigator.geolocation){
  const fail=(_ok,error)=>{queueMicrotask(()=>error?.({code:1,message:'Permission denied',PERMISSION_DENIED:1}));return 0;};
  install(navigator.geolocation,'getCurrentPosition',fail);install(navigator.geolocation,'watchPosition',fail);install(navigator.geolocation,'clearWatch',()=>{});
 }
 if(globalThis.Notification){install(Notification,'requestPermission',()=>Promise.resolve('denied'));try{Object.defineProperty(Notification,'permission',{get:()=> 'denied',configurable:false});}catch{}}
 for(const [object,methods] of [[navigator.mediaDevices,['getUserMedia','getDisplayMedia','enumerateDevices']],[navigator.bluetooth,['requestDevice']],[navigator.usb,['requestDevice']],[navigator.hid,['requestDevice']],[navigator.serial,['requestPort']],[navigator.clipboard,['read','readText','write','writeText']],[navigator,['requestMIDIAccess']]])
  if(object)for(const name of methods)install(object,name,denied);
 if(navigator.permissions)install(navigator.permissions,'query',()=>Promise.resolve(Object.assign(new EventTarget(),{state:'denied',onchange:null})));
})();
"""#
}
