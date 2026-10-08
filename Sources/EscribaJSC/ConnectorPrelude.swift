let connectorPreludeSource = #"""
(() => {
  const call = globalThis.__connectorCall, schedule = globalThis.__connectorTimer, clear = globalThis.__connectorClearTimer
  delete globalThis.__connectorCall; delete globalThis.__connectorTimer; delete globalThis.__connectorClearTimer
  const pending = new Map(), timers = new Map(), attachments = new WeakMap(), errorTokens = new WeakMap()
  let timerID = 0
  const rpc = request => new Promise((resolve, reject) => pending.set(call(JSON.stringify(request)), {resolve,reject}))
  globalThis.setTimeout = (fn, ms = 0, ...args) => {
    if (typeof fn !== 'function' || !Number.isFinite(ms) || ms < 0) throw new TypeError('temporizador no válido')
    if (timers.size >= 1024) throw new Error('demasiados temporizadores')
    const id = ++timerID; timers.set(id, () => fn(...args)); schedule(id, ms); return id
  }
  globalThis.clearTimeout = id => { timers.delete(id); clear(id) }
  globalThis.console = Object.freeze({log(){},warn(){},error(){},info(){},debug(){}})
  globalThis.TextEncoder = class { encode(text = '') { return Uint8Array.from(unescape(encodeURIComponent(String(text))), x => x.charCodeAt(0)) } }
  globalThis.TextDecoder = class { decode(value = new Uint8Array()) {
    const bytes = new Uint8Array(value.buffer ?? value, value.byteOffset ?? 0, value.byteLength)
    let text = ''; for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i,i+8192))
    return decodeURIComponent(escape(text))
  } }
  globalThis.Headers = class {
    constructor(input = {}) { this.values = new Map(); if (input instanceof Headers) input = [...input]; if (Array.isArray(input)) for (const [k,v] of input) this.append(k,v); else for (const [k,v] of Object.entries(input)) this.set(k,v) }
    set(key,value) { key = String(key).toLowerCase(); value = String(value); if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(key) || /[\r\n]/.test(value)) throw new TypeError('cabecera inválida'); this.values.set(key,value) }
    append(k,v) { const old = this.get(k); this.set(k, old === null ? v : old + ', ' + v) }
    get(k) { return this.values.get(String(k).toLowerCase()) ?? null }
    has(k) { return this.values.has(String(k).toLowerCase()) }
    delete(k) { this.values.delete(String(k).toLowerCase()) }
    entries() { return this.values.entries() }
    keys() { return this.values.keys() }
    forEach(fn) { this.values.forEach((v,k) => fn(v,k,this)) }
    [Symbol.iterator]() { return this.entries() }
  }
  globalThis.URLSearchParams = class {
    constructor(input = '') { this.pairs = typeof input === 'string' ? input.replace(/^\?/,'').split('&').filter(Boolean).map(p => { const at = p.indexOf('='); return [at < 0 ? p : p.slice(0,at), at < 0 ? '' : p.slice(at+1)].map(x => decodeURIComponent(x.replace(/\+/g,' '))) }) : Array.isArray(input) ? input.map(([k,v]) => [String(k),String(v)]) : Object.entries(input).map(([k,v]) => [k,String(v)]) }
    append(k,v) { this.pairs.push([String(k),String(v)]) }
    set(k,v) { this.delete(k); this.append(k,v) }
    delete(k) { this.pairs = this.pairs.filter(([key]) => key !== k) }
    get(k) { return this.pairs.find(([key]) => key === k)?.[1] ?? null }
    toString() { return this.pairs.map(pair => pair.map(x => encodeURIComponent(x).replace(/%20/g,'+')).join('=')).join('&') }
    [Symbol.iterator]() { return this.pairs[Symbol.iterator]() }
  }
  globalThis.URL = class {
    constructor(input,base) {
      let text = String(input); if (base && !/^[a-z]+:/i.test(text)) { const parent = new URL(base); text = parent.origin + (text.startsWith('/') ? text : parent.pathname.replace(/[^/]*$/,'') + text) }
      const m = /^(https?):\/\/([^/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(text)
      if (!m || m[2].includes('@')) throw new TypeError('URL no compatible')
      this.protocol = m[1]+':'; this.host = m[2]; this.origin = this.protocol+'//'+this.host; this.pathname = m[3] || '/'; this.searchParams = new URLSearchParams(m[4] || ''); this.hash = m[5] || ''
    }
    get search() { const s = this.searchParams.toString(); return s ? '?'+s : '' }
    set search(s) { this.searchParams = new URLSearchParams(s) }
    get href() { return this.origin+this.pathname+this.search+this.hash }
    toString() { return this.href }
    toJSON() { return this.href }
  }
  globalThis.Blob = class {
    constructor(parts = [], options = {}) { if (parts.length) throw new TypeError('Blob solo admite adjuntos del host'); this.type = options.type || ''; this.size = 0 }
    async text() { throw new Error('el adjunto opaco no permite leer bytes en JavaScript') }
    async arrayBuffer() { throw new Error('el adjunto opaco no permite leer bytes en JavaScript') }
    slice(start = 0, end = this.size, type = '') {
      const source = attachments.get(this); if (!source) throw new TypeError('adjunto desconocido')
      const normalize = n => n < 0 ? Math.max(this.size + Math.trunc(n),0) : Math.min(Math.trunc(n),this.size)
      start = normalize(start); end = normalize(end)
      const data = new Blob([],{type}), length = Math.max(end-start,0)
      data.size=length; attachments.set(data,{...source,offset:(source.offset || 0)+start,length,contentType:type || source.contentType})
      return data
    }
  }
  globalThis.FormData = class {
    constructor() { this.parts = [] }
    append(name,value,filename) { this.parts.push([String(name),value,filename]) }
    [Symbol.iterator]() { return this.parts.map(([k,v]) => [k,v])[Symbol.iterator]() }
  }
  globalThis.AbortController = class {
    constructor() { const listeners = new Set(); this.signal = {aborted:false,reason:undefined,addEventListener:(event,fn)=>{if(event==='abort')listeners.add(fn)},removeEventListener:(event,fn)=>listeners.delete(fn),throwIfAborted(){if(this.aborted)throw this.reason}}; this.abort = (reason = new Error('operación cancelada')) => {this.signal.aborted=true;this.signal.reason=reason;for(const fn of listeners)fn()} }
  }
  globalThis.crypto = Object.freeze({subtle: Object.freeze({ importKey: async()=>{throw new Error('criptografía de webhooks no disponible en el host')}, sign: async()=>{throw new Error('criptografía de webhooks no disponible en el host')} }), getRandomValues(){throw new Error('aleatoriedad criptográfica no disponible')} })
  const fetch = async (input, options = {}) => {
    options.signal?.throwIfAborted()
    const request = {op:'http',url:String(input),method:options.method || 'GET',headers:Object.fromEntries(new Headers(options.headers))}
    if (options.body instanceof FormData) request.multipart = options.body.parts.map(([name,value,filename]) => {
      if (value instanceof Blob) { const attachment = attachments.get(value); if (!attachment) throw new TypeError('adjunto desconocido'); return {name,attachment:attachment.id,filename:filename || attachment.filename,contentType:attachment.contentType,offset:attachment.offset || 0,length:attachment.length ?? attachment.size} }
      return {name,value:String(value)}
    })
    else if (options.body !== undefined && options.body !== null) { if (typeof options.body !== 'string') throw new TypeError('cuerpo HTTP no compatible'); request.body=options.body }
    const result = await rpc(request)
    options.signal?.throwIfAborted()
    const headers = new Headers(result.headers), body = result.body ?? ''
    return {status:result.status,ok:result.status>=200&&result.status<300,headers,url:request.url,statusText:'',text:async()=>body,json:async()=>JSON.parse(body)}
  }
  const host = Object.freeze({fetch,files:Object.freeze({snapshot:()=>rpc({op:'files.snapshot'}),apply:changes=>rpc({op:'files.apply',changes})}),audio:async()=>{const value=await rpc({op:'audio'});if(!value)return null;const data=new Blob([],{type:value.contentType});data.size=value.size;attachments.set(data,value);return {data,filename:value.filename}},checkpoint:receipt=>rpc({op:'checkpoint',receipt})})
  return {
    inspect(request,done,fail) { Promise.resolve().then(()=>{if(typeof globalThis.__conectores?.inspect!=='function')throw new Error('falta __conectores.inspect');return globalThis.__conectores.inspect()}).then(value=>done(JSON.stringify(value ?? null)),error=>fail(String(error),0)) },
    run(request, done, fail) { Promise.resolve().then(()=>{if(typeof globalThis.__conectores?.run!=='function')throw new Error('falta __conectores.run');return globalThis.__conectores.run(JSON.parse(request),host)}).then(value=>done(JSON.stringify(value ?? null)),error=>fail(String(error),errorTokens.get(error) || 0)) },
    resolve(id,text) {const entry=pending.get(id);pending.delete(id);if(entry){try{entry.resolve(JSON.parse(text))}catch(error){entry.reject(error)}}},
    reject(id,message) {const entry=pending.get(id);pending.delete(id);const error=new Error(message);errorTokens.set(error,id);entry?.reject(error)},
    fire(id) {const fn=timers.get(id);timers.delete(id);if(fn)fn()}
  }
})()
"""#
