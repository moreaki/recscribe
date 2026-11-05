const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
 assert(process.env.RECSCRIBE_RUN_DIR,'Use work-artifacts.py');
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage({viewport:{width:1152,height:1200},deviceScaleFactor:1.25,colorScheme:'light'});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const url=pathToFileURL(path.join(__dirname,'recording.html')).href;
  await page.goto(url);await page.evaluate(()=>localStorage.clear());await page.reload();
  const frame=page.frameLocator('iframe'),app=frame.locator('.rs-app');await app.waitFor({timeout:5000});assert.deepEqual(errors,[]);
  const act=name=>app.locator(`[data-action="${name}"]`).first();
  const theme=async value=>app.locator('.rs-appearance select').selectOption(value);
  const shot=async(name,element=app)=>{const h=await app.evaluate(el=>el.offsetHeight),width=page.viewportSize().width;await page.setViewportSize({width,height:Math.ceil(h)+140});await page.locator('iframe').evaluate((el,h)=>el.style.height=(h+70)+'px',h);await element.screenshot({path:path.join(process.env.RECSCRIBE_RUN_DIR,name+'.png')})};
  async function pair(name,element=app){await theme('light');await shot(name+'-light',element);await theme('dark');await shot(name+'-dark',element);await theme('light');}
  async function restore(values){await app.evaluate((el,next)=>el.ownerDocument.defaultView.dispatchEvent(new CustomEvent('openai:set_globals',{detail:{globals:{widgetState:{privateContent:{extensionVersion:2,Focus:next}}}}})),values);}
  async function fits(width){const over=await app.evaluate(el=>{const r=el.getBoundingClientRect();return [...el.querySelectorAll('button,input,select,h1,h2,p')].filter(x=>x.getClientRects().length).filter(x=>{const b=x.getBoundingClientRect();return b.left<r.left-1||b.right>r.right+1}).map(x=>x.textContent.slice(0,60))});assert.deepEqual(over,[],`Overflow at ${width}`)}
  assert.equal(await app.getAttribute('data-capture-phase'),'recording');assert.equal(await app.locator('#rs-capture-information').count(),0);assert.equal(await app.locator('.rs-draft-body').count(),0);assert((await app.textContent()).includes('audio recording continues'));
  assert((await app.locator('.rs-capture-wave>span').count())<=123);await pair('recording-active');
  await app.locator('[data-input=liveText]').check();assert.equal(await app.locator('.rs-draft-body').count(),1);await pair('recording-transcription');await act('follow-live').click();assert.equal(await act('follow-live').getAttribute('aria-pressed'),'false');await app.locator('[data-input=liveText]').uncheck();
  await act('capture-info').click();assert((await app.locator('#rs-capture-information').textContent()).includes('original source tracks'));await pair('recording-info');await act('capture-info').focus();await page.keyboard.press('Escape');assert.equal(await app.locator('#rs-capture-information').count(),0);assert(await act('capture-info').evaluate(el=>el===el.ownerDocument.activeElement));
  await act('capture-mute-mic').click();assert.equal(await act('capture-mute-mic').getAttribute('aria-pressed'),'true');assert.equal(await app.locator('[data-capture-meter=mic]').getAttribute('style'),'width: 0%;');await act('capture-mute-mic').click();
  for(const value of ['light','dark']){await theme(value);await act('open-menubar').click();await shot('menubar-recording-'+value,app.locator('.rs-menubar-dialog'));await act('close-menubar').click();}
  await theme('light');await act('stop').click();assert.equal(await app.getAttribute('data-capture-phase'),'stopping');assert.equal(await act('capture-wait').isDisabled(),true);await shot('recording-saving');await app.locator('[data-capture-status]').filter({hasText:'Recording saved'}).waitFor();await pair('recording-saved');
  await act('new-session').click();await pair('recording-ready');
  for(const value of ['light','dark']){await theme(value);await act('open-menubar').click();await shot('menubar-ready-'+value,app.locator('.rs-menubar-dialog'));await act('menu-info').click();assert((await app.locator('.rs-menu-explanation').textContent()).includes('full recording view'));await shot('menubar-info-'+value,app.locator('.rs-menubar-dialog'));await act('close-menubar').click();}
  await theme('light');await act('studio').click();const title=await app.locator('h1').textContent();await act('open-menubar').click();await act('start').click();assert.equal(await app.getAttribute('data-capture-phase'),'starting');assert.equal(await app.locator('.rs-menubar-dialog').count(),0);assert.equal(await app.locator('.rs-capture-body').count(),1);assert.equal(await act('live').getAttribute('aria-current'),'page');await shot('recording-starting');
  await app.locator('[data-capture-status]').filter({hasText:/^Recording$/}).waitFor();const wave0=await app.locator('.rs-capture-wave').evaluate(el=>[...el.children].map(x=>x.style.height).join(','));await page.waitForTimeout(200);const wave1=await app.locator('.rs-capture-wave').evaluate(el=>[...el.children].map(x=>x.style.height).join(','));assert.notEqual(wave0,wave1);
  await act('studio').click();assert.equal(await app.locator('h1').textContent(),title);assert.equal(await app.locator('.rs-live-banner').count(),1);await act('live').click();await act('stop').click();await app.locator('[data-capture-status]').filter({hasText:'Recording saved'}).waitFor();
  await restore({mode:'live',session:'recording',elapsed:42,signal:'silence',liveText:false,captureInfo:false});assert((await app.textContent()).includes('Silence detected'));await pair('recording-silence');
  await restore({signal:'no-data'});assert((await app.locator('[role=alert]').textContent()).includes('No input data'));await pair('recording-no-data');
  await restore({session:'partial',signal:'sound'});assert((await app.locator('[role=alert]').textContent()).includes('Capture ended early'));await pair('recording-partial');
  await restore({session:'recording',signal:'sound',captureInfo:false});
  for(const width of [1152,1024,940,760,620,360,320]){await page.setViewportSize({width,height:1200});await fits(width);if(width===360)await shot('recording-narrow');}
  await page.emulateMedia({reducedMotion:'reduce'});await page.reload();await app.waitFor();await restore({mode:'live',session:'ready',elapsed:0,signal:'sound',captureInfo:false,menuPopover:false});await act('start').click();await app.locator('[data-capture-status]').filter({hasText:/^Recording$/}).waitFor();const staticWave=await app.locator('.rs-capture-wave').evaluate(el=>[...el.children].map(x=>x.style.height).join(','));await page.waitForTimeout(1150);assert.equal(await app.locator('.rs-capture-wave').evaluate(el=>[...el.children].map(x=>x.style.height).join(',')),staticWave);assert.notEqual(await app.locator('.rs-capture-time').textContent(),'00:00:00');
  assert.deepEqual(errors,[]);
  console.log('PASS: default active waveform/live-off, optional draft/info/focus, source mute, compact menu/start-to-full transition, starting/saving/saved phases, bounded animated signal after explicit start, Studio context retention, silence/no-data/partial, light/dark, 320–1152px; no script errors. Synthetic UI; no native capture, permissions or audio tests.');
 } finally {await browser.close()}
})().catch(error=>{console.error(error);process.exit(1)});
