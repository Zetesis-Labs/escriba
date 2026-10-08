// Throwaway compatibility subset for the bundled Notion SDK, not a browser.
(() => {
  const host = globalThis.__host;
  delete globalThis.__host;
  const call = value => JSON.parse(host(JSON.stringify(value)));
  let next = 0;
  const pending = new Map(), timers = new Map();
  globalThis.__deliver = raw => {
    const value = JSON.parse(raw);
    if (value.timer) { const f = timers.get(value.id); timers.delete(value.id); if (f) f(); return; }
    const p = pending.get(value.id); if (!p) return;
    pending.delete(value.id);
    if (p.cleanup) p.cleanup();
    value.error ? p.reject(new Error(value.error)) : p.resolve(value);
  };
  globalThis.setTimeout = (f, ms = 0, ...args) => {
    const id = ++next; timers.set(id, () => f(...args)); call({op:'timer',id,ms:Number(ms)}); return id;
  };
  globalThis.clearTimeout = id => { timers.delete(id); call({op:'clearTimer',id}); };
  globalThis.AbortController = class {
    constructor() {
      const listeners = new Set();
      this.signal = {aborted:false, addEventListener:(_,f)=>listeners.add(f), removeEventListener:(_,f)=>listeners.delete(f)};
      this.abort = () => { if (this.signal.aborted) return; this.signal.aborted = true; for (const f of listeners) f(); };
    }
  };
  globalThis.URLSearchParams = class {
    constructor(value = '') {
      this.pairs = typeof value === 'string' ? value.replace(/^\?/, '').split('&').filter(Boolean).map(p => { const i=p.indexOf('='); return [i<0?p:p.slice(0,i),i<0?'':p.slice(i+1)].map(x=>decodeURIComponent(x.replace(/\+/g,' '))); }) : Array.isArray(value) ? value.map(p=>p.map(String)) : Object.entries(value).map(p=>p.map(String));
    }
    append(k,v) { this.pairs.push([String(k),String(v)]); }
    set(k,v) { this.delete(k); this.append(k,v); }
    get(k) { return this.pairs.find(p=>p[0]===k)?.[1] ?? null; }
    delete(k) { this.pairs=this.pairs.filter(p=>p[0]!==k); }
    toString() { return this.pairs.map(p=>p.map(encodeURIComponent).join('=')).join('&'); }
    [Symbol.iterator]() { return this.pairs[Symbol.iterator](); }
  };
  globalThis.URL = class {
    constructor(value, base) { const v=call({op:'url',value:String(value),base:base===undefined?null:String(base)}); if(v.error) throw new TypeError(v.error); Object.assign(this,v); this.searchParams=new URLSearchParams(this.search); }
    toString() { const q=this.searchParams.toString(); return this.origin+this.pathname+(q?'?'+q:'')+this.hash; }
    get href() { return this.toString(); }
  };
  const bytes = part => {
    if (part instanceof Blob) return part._bytes;
    if (part instanceof ArrayBuffer) return Array.from(new Uint8Array(part));
    if (ArrayBuffer.isView(part)) return Array.from(new Uint8Array(part.buffer,part.byteOffset,part.byteLength));
    return Array.from(unescape(encodeURIComponent(String(part))), c=>c.charCodeAt(0));
  };
  globalThis.Blob = class {
    constructor(parts=[],options={}) { this._bytes=parts.flatMap(bytes); this.type=options.type || ''; this.size=this._bytes.length; }
    async arrayBuffer() { return new Uint8Array(this._bytes).buffer; }
    async text() { return decodeURIComponent(escape(String.fromCharCode(...this._bytes))); }
    get [Symbol.toStringTag]() { return 'Blob'; }
  };
  globalThis.File = class extends Blob { constructor(parts,name,options={}) { super(parts,options); this.name=String(name); this.lastModified=options.lastModified || Date.now(); } get [Symbol.toStringTag]() { return 'File'; } };
  globalThis.FormData = class {
    constructor() { this._parts=[]; }
    append(name,value,filename) { this._parts.push(value instanceof Blob ? {name:String(name),bytes:value._bytes,type:value.type,filename:filename || value.name || 'blob'} : {name:String(name),value:String(value)}); }
    get [Symbol.toStringTag]() { return 'FormData'; }
  };
  globalThis.Headers = class {
    constructor(value={}) { this._values={}; if(value instanceof Headers) value=value._values; for(const [k,v] of Array.isArray(value)?value:Object.entries(value)) this.set(k,v); }
    get(k) { return this._values[k.toLowerCase()] ?? null; }
    set(k,v) { this._values[String(k).toLowerCase()]=String(v); }
    entries() { return Object.entries(this._values)[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
  };
  const fetch = (url,init={}) => new Promise((resolve,reject) => {
    const id=++next;
    const abort=()=> { call({op:'cancel',id}); pending.delete(id); const e=new Error('Request cancelled'); e.name='AbortError'; reject(e); };
    if(init.signal?.aborted) { abort(); return; }
    pending.set(id,{resolve:v=>resolve({status:v.status,statusText:v.statusText,ok:v.status>=200&&v.status<300,headers:new Headers(v.headers),text:async()=>v.text,json:async()=>JSON.parse(v.text)}),reject,cleanup:()=>init.signal?.removeEventListener('abort',abort)});
    init.signal?.addEventListener('abort',abort);
    const body=init.body instanceof FormData ? {multipart:init.body._parts} : init.body instanceof Blob ? {bytes:init.body._bytes,type:init.body.type} : init.body == null ? null : {text:String(init.body)};
    const result=call({op:'fetch',id,url:String(url),method:init.method || 'GET',headers:new Headers(init.headers)._values,body});
    if(result.error) globalThis.__deliver(JSON.stringify({id,error:result.error}));
  });
  globalThis.__contexto=Object.freeze({cuenta:Object.freeze({fetch}),checkpoint:async receipt=>{ const result=call({op:'checkpoint',receipt}); if(result.error)throw new Error(result.error); }});
  globalThis.__finish = value => call({op:'finish',...value});
  globalThis.console=Object.freeze({log:()=>{},warn:()=>{},error:()=>{},debug:()=>{}});
})();
