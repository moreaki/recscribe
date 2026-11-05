const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
  assert(process.env.RECSCRIBE_RUN_DIR,'Run through scripts/work-artifacts.py');
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_PATH?{executablePath:process.env.CHROME_PATH}:{})});
  const page=await browser.newPage({viewport:{width:1120,height:1050},deviceScaleFactor:1.5});
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  const url=pathToFileURL(path.join(__dirname,'recordings.html')).href;
  async function scene(s){await page.goto(url+'?scene='+s);await page.evaluate(()=>document.fonts.ready)}
  async function shot(s){await page.locator('.app').screenshot({path:path.join(process.env.RECSCRIBE_RUN_DIR,s+'.png')})}
  for(const state of ['browse','selected','all','confirm','exceptions','progress','result','blocked','empty']){await scene(state);await shot(state)}
  await scene('browse');assert(await page.locator('[data-action=delete]').isDisabled());
  await page.locator('[data-select="1"]').check();
  await page.locator('[data-select="3"]').click({modifiers:['Shift']});
  assert.equal(await page.locator('[data-select]:checked').count(),3);
  assert(await page.locator('#master').evaluate(x=>x.indeterminate));
  await page.locator('#master').check();assert.equal(await page.locator('[data-select]:checked').count(),5);
  await page.keyboard.press('Escape');assert.equal(await page.locator('[data-select]:checked').count(),0);
  await page.keyboard.press('Meta+a');assert.equal(await page.locator('[data-select]:checked').count(),5);
  await page.locator('[data-action=delete]').click();assert(await page.locator('[value=audio]').isChecked());
  assert.equal(await page.locator('.content').getAttribute('inert'),'');
  assert.equal(await page.locator('[data-action=cancel]').evaluate(x=>x===document.activeElement),true);
  await page.locator('[value=audio]').focus();await page.keyboard.press('Shift+Tab');assert.equal(await page.locator('[data-action=confirm]').evaluate(x=>x===document.activeElement),true);
  await page.keyboard.press('Tab');assert.equal(await page.locator('[value=audio]').evaluate(x=>x===document.activeElement),true);
  await page.keyboard.press('Escape');assert.equal(await page.locator('.sheet').count(),0);
  assert.equal(await page.locator('[data-action=delete]').evaluate(x=>x===document.activeElement),true);
  await scene('selected');await page.locator('[data-action=delete]').click();await page.locator('[value=linked]').check();
  assert((await page.locator('.option.active').textContent()).includes('3 verified jobs'));
  await page.locator('[data-action=confirm]').click();await page.locator('.sheet').waitFor({state:'detached'});
  assert.equal(await page.locator('.row').count(),2);assert((await page.locator('.footer').textContent()).includes('3 transcript jobs'));
  await scene('exceptions');assert((await page.locator('.warning').textContent()).includes('does not remove all transcription data'));
  await page.locator('[value=audio]').check();assert.equal(await page.locator('.warning').count(),0);
  await scene('result');assert.equal(await page.locator('[data-select]:checked').count(),1);assert.equal(await page.locator('[data-select="3"]').isChecked(),true);
  await scene('blocked');assert(await page.locator('[data-action=delete]').isDisabled());assert.equal(await page.locator('[data-select]:checked').count(),3);
  await scene('browse');await page.locator('[data-action=menu][data-id="1"]').click();await page.locator('[data-action=single-delete]').click();
  assert((await page.locator('#dialog-title').textContent()).includes('1 recording?'));await page.locator('[data-action=cancel]').click();assert.equal(await page.locator('.row').count(),5);
  for(const width of [620,760,1120]){await page.setViewportSize({width,height:1050});for(const state of ['browse','selected','all','confirm','exceptions','result','blocked','empty']){await scene(state);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Page overflow: '+width+' '+state);assert(await page.evaluate(()=>[...document.querySelectorAll('.app button,.app input')].filter(x=>x.getClientRects().length).every(x=>{const r=x.getBoundingClientRect(),a=document.querySelector('.app').getBoundingClientRect();return r.left>=a.left&&r.right<=a.right})),'Control overflow: '+width+' '+state)}if(width===620){await scene('selected');await shot('narrow');await scene('confirm');await shot('narrow-confirm')}}
  assert.deepEqual(errors,[]);await browser.close();
  console.log('PASS: mock selection/range/all/clear, default scope, confirmation/cancel/focus, simulated linked-data deletion, exceptions, partial-result retention, capture guard, row delete; 620/760/1120 widths; no script errors. Synthetic UI only; no native app or filesystem deletion tests.');
})().catch(e=>{console.error(e);process.exit(1)});
