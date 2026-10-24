import{n as y}from"./rolldown-runtime-CRqgUL4m.js";import{D as b,On as x,St as h,_ as o,b as k,g as F,k as g,mt as E,un as C,vn as a}from"./runtime-core.esm-bundler-CD9fp9Xz.js";import{i as w}from"./core-CwxD5AgE.js";import{t as A}from"./analysis-WZ5ZN_d6.js";import{t as D}from"./useEcharts-BXLsPWlj.js";var L={class:"mine-card w-auto xl:w-8/12"},S={class:"flex items-center justify-between text-base"},$={class:"w-180px"},B=g({__name:"analysis-content-publish",setup(N){const l=a("today"),r=a([]),n=a([]),i=a([]),u=a([]),c=a(),s=w(),{contentPublishRadio:d}=A(),p=d();r.value=p[0].x,p.forEach(e=>{e.name==="纯文本"?n.value=e.y:e.name==="图文类"&&(i.value=e.y),u.value=e.y});function m(e){return e.map(t=>`<div class="content-panel">
      <p>
        <span style="background-color: ${t.color}" class="tooltip-item-icon"></span>
      <span>
        ${t.seriesName}
      </span>
    </p>
    <span class="tooltip-value">
      ${Number(t.value).toLocaleString()}
    </span>
  </div>`).join("")}const v=F(()=>({grid:{left:"4%",right:0,top:"20",bottom:"60"},legend:{bottom:0,icon:"circle",textStyle:{color:"#4E5969"}},xAxis:{type:"category",data:r.value,axisLine:{lineStyle:{color:s.value==="dark"?"#3f3f3f":"#A9AEB8"}},axisTick:{show:!0,alignWithLabel:!0,lineStyle:{color:"#86909C"}},axisLabel:{color:"#86909C"}},yAxis:{type:"value",axisLabel:{color:"#86909C",formatter(e,t){return t===0?`${e}`:`${e/1e3}k`}},splitLine:{lineStyle:{color:s.value==="dark"?"#3F3F3F":"#E5E6EB"}}},tooltip:{show:!0,trigger:"axis",formatter(e){const[t]=e;return`
          <div>
            <p class="tooltip-title">
              ${t.axisValueLabel}
            </p>
            ${m(e)}
          </div>
        `},className:"echarts-tooltip-diy"},series:[{name:"纯文本",data:n.value,stack:"one",type:"bar",barWidth:16,color:s.value==="dark"?"#4A7FF7":"#246EFF"},{name:"图文类",data:i.value,stack:"one",type:"bar",color:s.value==="dark"?"#085FEF":"#00B2FF"},{name:"视频类",data:u.value,stack:"one",type:"bar",color:s.value==="dark"?"#01349F":"#81E2FF",itemStyle:{borderRadius:2}}]}));return D(c).setOption(v.value),(e,t)=>{const _=h("m-tabs");return E(),k("div",L,[o("div",S,[t[1]||(t[1]=o("div",null,"内容发布比例",-1)),o("div",$,[b(_,{modelValue:x(l),"onUpdate:modelValue":t[0]||(t[0]=f=>C(l)?l.value=f:null),class:"h-7 w-full text-sm",options:[{label:"一周内",value:"week"},{label:"昨日",value:"yesterday"},{label:"今日",value:"today"}]},null,8,["modelValue"])])]),o("div",{ref_key:"echarts",ref:c,class:"mt-5 h-300px"},null,512)])}}}),M=y({default:()=>V}),V=B;export{M as n,V as t};
