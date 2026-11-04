// Local design-artifact checks; no devices, network or app state are accessed.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try {
    const page=await browser.newPage({viewport:{width:1160,height:840},deviceScaleFactor:2});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(pathToFileURL(path.join(__dirname,'source-strip.html')).href);
    const mic=page.locator('[data-id=mic]');
    const height=()=>mic.evaluate(e=>e.getBoundingClientRect().height);
    assert.equal(await height(),112);
    await mic.locator('.mute').click();
    assert.equal(await height(),112);
    assert.equal(await mic.locator('.raw output').textContent(),'-18');
    assert.equal(await mic.locator('.mix output').textContent(),'−∞');
    await mic.locator('.gain-number').fill('6');await mic.locator('.gain-number').press('Tab');
    assert.equal(await mic.locator('.gain-slider').inputValue(),'6');
    await mic.locator('.reset').click();assert.equal(await mic.locator('.gain-number').inputValue(),'0');
    assert.equal(await mic.locator('.mute').getAttribute('aria-pressed'),'true');
    await page.locator('#test').click(); // idle: source and route editing is available
    const left=mic.locator('.route.left'),right=mic.locator('.route.right');
    await left.click();assert.equal(await left.getAttribute('aria-pressed'),'false');
    assert.equal(await right.getAttribute('aria-pressed'),'true');
    await right.click();assert.equal(await right.getAttribute('aria-pressed'),'false');
    await right.click();await left.click();
    const teams=page.locator('[data-id=teams]');
    await teams.locator('.capture-check').check();await teams.locator('.mute').click();
    await teams.locator('.gain-number').fill('3');await teams.locator('.gain-number').press('Tab');
    await teams.locator('.capture-check').uncheck();await teams.locator('.capture-check').check();
    assert.equal(await teams.locator('.mute').getAttribute('aria-pressed'),'true');
    assert.equal(await teams.locator('.gain-number').inputValue(),'3');
    assert.equal(await height(),112);
    await page.locator('#test').click();
    await teams.locator('.mute').click();
    assert.equal(await teams.locator('.mix output').textContent(),'-21');
    await page.locator('#test').click();
    await page.locator('#scenario').selectOption('recording');
    assert(await teams.locator('.capture-check').isDisabled());
    assert(await mic.locator('.route.left').isDisabled());
    assert(await mic.locator('.mute').isEnabled());assert(await mic.locator('.gain-number').isEnabled());
    await page.locator('#scenario').selectOption('overview');
    assert(await mic.locator('.route.left').isDisabled()); // testing locks connection edits too
    await page.screenshot({path:path.join(__dirname,'overview.png'),fullPage:true});
    await page.locator('#scenario').selectOption('muted');
    await page.screenshot({path:path.join(__dirname,'muted.png'),fullPage:true});
    await page.locator('#scenario').selectOption('multichannel');
    await page.locator('#test').click();
    const iface=page.locator('[data-id=interface]');
    await iface.locator('.channels').evaluate(e=>e.scrollLeft=e.scrollWidth);
    const ch32=iface.locator('[data-channel="31"]');
    assert(await ch32.locator('.right').isVisible());
    const positions=await ch32.evaluate(e=>{const a=e.getBoundingClientRect(),b=e.parentElement.getBoundingClientRect();return {left:a.left,right:a.right,min:b.left,max:b.right};});
    assert(positions.left>=positions.min-1&&positions.right<=positions.max+1,'last channel is reachable');
    await ch32.locator('input').fill('-3');await ch32.locator('input').press('Tab');
    await iface.locator('.level-channel').selectOption('31');
    await iface.locator('.hw-channel').selectOption('32');
    await iface.locator('.hw-slider').fill('80');await iface.locator('.hw-channel').selectOption('1');
    assert.equal(await iface.locator('.hardware-value').textContent(),'42%');
    await iface.locator('.hw-channel').selectOption('32');assert.equal(await iface.locator('.hardware-value').textContent(),'80%');
    await iface.locator('.channels').evaluate(e=>e.scrollLeft=0);
    await page.locator('#test').click();
    assert.equal(await iface.locator('.raw output').textContent(),'-12');
    assert.equal(await iface.locator('.mix output').textContent(),'-15');
    await iface.locator('.level-channel').selectOption('all');
    await page.screenshot({path:path.join(__dirname,'multichannel.png'),fullPage:true});
    for(const width of [1040,760,620]){
      await page.locator('#width').selectOption(String(width));
      await page.setViewportSize({width:width+32,height:840});
      for(const scenario of ['overview','muted','multichannel','offline','recording']){
        await page.locator('#scenario').selectOption(scenario);
        const overflow=await page.evaluate(()=>({document:document.documentElement.scrollWidth>innerWidth,
          bad:[...document.querySelectorAll('.source')].flatMap(card=>{
            const b=card.getBoundingClientRect();const found=[];
            if(b.height!==112)found.push('height '+b.height);
            for(const el of card.querySelectorAll('button,input,select,.meter-line,.group-head')){
              if(el.closest('.channel'))continue; // deliberate bounded horizontal scrolling
              const r=el.getBoundingClientRect();if(r.width&&(r.left<b.left||r.right>b.right||r.bottom>b.bottom))found.push(el.className||el.tagName);
            }return found;
          })}));
        assert(!overflow.document,`document overflow at ${width} ${scenario}`);
        assert.deepEqual(overflow.bad,[],`card controls overflow at ${width} ${scenario}`);
      }
    }
    await page.locator('#scenario').selectOption('muted');
    await page.screenshot({path:path.join(__dirname,'narrow.png'),fullPage:true});
    await page.locator('#scenario').selectOption('offline');
    assert(await mic.locator('.hw-slider').isDisabled());
    assert(await mic.locator('.mute').isEnabled());
    assert.equal(await mic.locator('.raw output').textContent(),'−∞');
    await page.screenshot({path:path.join(__dirname,'reconnecting.png'),fullPage:true});
    assert.deepEqual(errors,[]);
    console.log('PASS: fixed 112px cards; mute/raw signal; gain/reset; independent L/R; virtual capture preferences; capture locks; 32 channels/hardware controls; 1040/760/620px layouts; no script errors.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
