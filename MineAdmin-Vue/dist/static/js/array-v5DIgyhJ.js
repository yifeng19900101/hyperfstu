var c=(a,s,e=!1)=>{if(!a)return[];const r=(n,o)=>s(n)-s(o),t=(n,o)=>s(o)-s(n);return a.slice().sort(e===!0?t:r)},l=(a,s,e)=>{let r=e;for(let t=1;t<=a;t++)r=s(r,t);return r};export{c as n,l as t};
