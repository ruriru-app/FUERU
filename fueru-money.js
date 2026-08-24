(function(global){
  "use strict";

  var currency={
    code:"JPY",
    unit:"円",
    locale:"ja-JP",
    position:"suffix",
    decimals:0,
    withdrawalSteps:[1,10,100,500,1000]
  };

  function configure(next){
    if(!next||typeof next!=="object")return getCurrency();
    if(typeof next.code==="string"&&next.code.trim())currency.code=next.code.trim();
    if(typeof next.unit==="string"&&next.unit.trim())currency.unit=next.unit.trim();
    if(typeof next.locale==="string"&&next.locale.trim())currency.locale=next.locale.trim();
    if(next.position==="prefix"||next.position==="suffix")currency.position=next.position;
    if(Number.isInteger(next.decimals)&&next.decimals>=0&&next.decimals<=6)currency.decimals=next.decimals;
    if(Array.isArray(next.withdrawalSteps)){
      var steps=next.withdrawalSteps.map(Number).filter(function(value){return Number.isInteger(value)&&value>0;});
      if(steps.length)currency.withdrawalSteps=Array.from(new Set(steps)).sort(function(a,b){return a-b;});
    }
    return getCurrency();
  }

  function getCurrency(){return Object.assign({},currency,{withdrawalSteps:currency.withdrawalSteps.slice()});}

  function number(value){
    var amount=Number(value)||0;
    return Math.abs(amount).toLocaleString(currency.locale,{
      minimumFractionDigits:currency.decimals,
      maximumFractionDigits:currency.decimals
    });
  }

  function attachUnit(value){
    return currency.position==="prefix"?currency.unit+value:value+currency.unit;
  }

  function format(value){
    var amount=Number(value)||0;
    return (amount<0?"－":"")+attachUnit(number(amount));
  }

  function signed(value,showPlus){
    var amount=Number(value)||0;
    var sign=amount<0?"－":showPlus===true?"＋":"";
    return sign+attachUnit(number(amount));
  }

  function negative(value){
    var amount=Math.abs(Number(value)||0);
    return amount?"－"+attachUnit(number(amount)):attachUnit(number(0));
  }

  function unit(){return currency.unit;}
  function unitStep(value){return format(Math.abs(Number(value)||0))+"単位";}
  function withdrawalSteps(){return currency.withdrawalSteps.slice();}

  global.FueruMoney=Object.freeze({
    configure:configure,
    getCurrency:getCurrency,
    format:format,
    signed:signed,
    negative:negative,
    unit:unit,
    unitStep:unitStep,
    withdrawalSteps:withdrawalSteps
  });
})(window);
