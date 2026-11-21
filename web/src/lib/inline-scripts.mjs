// @ts-check

export const JS_CLASS =
  "document.documentElement.classList.add('js');addEventListener('error',e=>{if(e.target.type=='module'||document.readyState!='complete'&&e.filename?.startsWith(origin+'/_astro/'))document.documentElement.classList.remove('js')},true)";

export const HERO_SEEN =
  "try{if(sessionStorage.getItem('hasala:hero'))document.documentElement.classList.add('hero-seen');else sessionStorage.setItem('hasala:hero','1')}catch(e){}";

export const INVITE_CODE = "if(/^\\/i\\/./.test(location.pathname)||location.hash.length>1){let c=document.documentElement.classList;c.add('has-code');addEventListener('error',()=>{c.contains('js')||document.querySelector('[data-code]:not([hidden])')||c.remove('has-code')},true)}";

export const INLINE_SCRIPTS = [JS_CLASS, HERO_SEEN, INVITE_CODE];
