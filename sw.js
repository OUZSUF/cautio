/* Kafil : ouverture instantanée (page gardée sur l'appareil), fonctionne sans réseau et reçoit les rappels */
const C='kafil-v2';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(['/','/manifest.webmanifest','/icon-192.png'])).catch(()=>{}));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
const sig=r=>r?(r.headers.get('etag')||'')+'|'+(r.headers.get('last-modified')||'')+'|'+(r.headers.get('content-length')||''):'';
/* nouvelle version en arrière-plan : on la garde pour la prochaine ouverture et on prévient la page */
async function rafraichir(){try{const c=await caches.open(C),old=await c.match('/'),res=await fetch('/',{cache:'no-cache'});
  if(!res.ok)return;const nv=sig(res);await c.put('/',res.clone());
  if(old&&sig(old)!==nv&&nv!=='||'){const l=await self.clients.matchAll({type:'window'});l.forEach(w=>w.postMessage({type:'kafil-maj'}))}}catch(e){}}
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;
  if(r.mode==='navigate'){
    /* page d'accueil sans paramètres : copie de l'appareil tout de suite, mise à jour en arrière-plan */
    if((u.pathname==='/'||u.pathname==='/index.html')&&!u.search){e.respondWith(caches.match('/').then(m=>{const net=rafraichir();if(m){e.waitUntil(net);return m}
        return fetch(r).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put('/',cp));return res})}).catch(()=>fetch(r)));return}
    e.respondWith(fetch(r).then(res=>{if(u.pathname==='/'){const cp=res.clone();caches.open(C).then(c=>c.put('/',cp))}return res}).catch(()=>caches.match('/')));return}
  e.respondWith(caches.match(r).then(m=>m||fetch(r)))});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch(x){d={body:e.data&&e.data.text()}}
  e.waitUntil(self.registration.showNotification(d.title||'Kafil',{body:d.body||'',icon:'/icon-192.png',tag:d.tag||'kafil-rappel',renotify:true,lang:d.lang||'fr',dir:d.lang==='ar'?'rtl':'ltr',data:{url:d.url||'/#accueil'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const url=e.notification.data&&e.notification.data.url||'/#accueil';
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{for(const w of l){if('focus' in w){w.navigate&&w.navigate(url).catch(()=>{});return w.focus()}}return self.clients.openWindow(url)}))});
