/* Kafil : fonctionne sans réseau (page déjà ouverte) et reçoit les rappels */
const C='kafil-v1';
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(['/','/manifest.webmanifest','/icon-192.png'])).catch(()=>{}));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{const r=e.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==location.origin)return;
  /* la page : réseau d'abord pour toujours avoir la dernière version, copie en secours */
  if(r.mode==='navigate'){e.respondWith(fetch(r).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put('/',cp));return res}).catch(()=>caches.match('/')));return}
  e.respondWith(caches.match(r).then(m=>m||fetch(r)))});
self.addEventListener('push',e=>{let d={};try{d=e.data.json()}catch(x){d={body:e.data&&e.data.text()}}
  e.waitUntil(self.registration.showNotification(d.title||'Kafil',{body:d.body||'',icon:'/icon-192.png',tag:d.tag||'kafil-rappel',renotify:true,lang:d.lang||'fr',dir:d.lang==='ar'?'rtl':'ltr',data:{url:d.url||'/#accueil'}}))});
self.addEventListener('notificationclick',e=>{e.notification.close();const url=e.notification.data&&e.notification.data.url||'/#accueil';
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>{for(const w of l){if('focus' in w){w.navigate&&w.navigate(url).catch(()=>{});return w.focus()}}return self.clients.openWindow(url)}))});
