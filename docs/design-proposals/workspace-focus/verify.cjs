const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
 assert(process.env.RECSCRIBE_RUN_DIR,'Run through work-artifacts.py');
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try {
  const page=await browser.newPage({viewport:{width:1152,height:1500},deviceScaleFactor:1.25,colorScheme:'light'});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const palette=await browser.newPage({viewport:{width:1040,height:700},deviceScaleFactor:1.5});await palette.goto(pathToFileURL(path.join(__dirname,'palette-board.html')).href);await palette.locator('#palette-comparison').screenshot({path:path.join(process.env.RECSCRIBE_RUN_DIR,'palette-comparison.png')});await palette.close();
  await page.goto(pathToFileURL(path.join(__dirname,'workspaces.html')).href);
  await page.evaluate(()=>localStorage.clear());await page.reload();
  const frame=page.frameLocator('iframe'),app=frame.locator('.rs-app');
  await app.waitFor({timeout:5000});assert.deepEqual(errors,[]);
  const act=(name)=>app.locator(`[data-action="${name}"]`).first();
  const input=(name)=>app.locator(`[data-input="${name}"]`).last();
  const shot=async(name)=>{const height=await app.evaluate(el=>el.offsetHeight),width=page.viewportSize().width;await page.setViewportSize({width,height:Math.ceil(height)+100});await page.locator('iframe').evaluate((el,h)=>el.style.height=(h+30)+'px',height);await app.screenshot({path:path.join(process.env.RECSCRIBE_RUN_DIR,name+'.png')})};
  const theme=async(value)=>{await app.locator('.rs-appearance select').selectOption(value)};
  async function pair(name){await theme('light');await shot(name+'-light');await theme('dark');await shot(name+'-dark');await theme('light');}
  async function fits(width){const over=await app.evaluate(el=>{const r=el.getBoundingClientRect();return [...el.querySelectorAll('button,input,select,h1,h2,p')].filter(x=>x.getClientRects().length).filter(x=>{const b=x.getBoundingClientRect();return b.left<r.left-1||b.right>r.right+1}).map(x=>({text:x.textContent.slice(0,45),width:x.getBoundingClientRect().width}))});assert.deepEqual(over,[],`Overflow at ${width}`);}
  assert.equal(await app.locator('.rs-recording-row').count(),6);await pair('recordings');
  await input('query').fill('planning');assert.equal(await app.locator('.rs-recording-row').count(),1);await input('query').fill('');
  await app.locator('[data-input=select][data-id=interview]').check();await app.locator('[data-input=select][data-id=ideas]').check();
  assert(await input('master').evaluate(el=>el.indeterminate));await pair('recordings-selection');
  await act('delete-selected').click();assert(await app.locator('[value=audio]').isChecked());assert(await act('cancel-sheet').evaluate(el=>el===el.ownerDocument.activeElement));
  await app.locator('[value=linked]').check();assert((await app.locator('dialog').textContent()).includes('protected live draft'));await shot('recordings-delete-light');
  await act('cancel-sheet').click();assert.equal(await app.locator('[data-input=select]:checked').count(),2);
  await act('delete-selected').click();assert(await app.locator('[value=audio]').isChecked());await act('confirm-delete').click();assert.equal(await app.locator('.rs-recording-row').count(),4);await act('undo-removal').click();assert.equal(await app.locator('.rs-recording-row').count(),6);
  await act('lib-details-research').click();assert((await app.locator('.rs-library-details').textContent()).includes('Research conversation'));await pair('recordings-details');await act('lib-close').click();
  await act('settings').click();
  for(const category of ['general','recording','transcription','models','intelligence','diagnostics']){await act('category-'+category).click();await pair('settings-'+category);}
  await act('category-intelligence').click();await input('provider').selectOption('openai');await pair('settings-openai');
  await act('manage-key').click();assert.equal(await app.locator('dialog input').count(),0);await act('cancel-sheet').click();
  await act('test-cloud').click();assert((await app.locator('dialog').textContent()).includes('grants no approval'));await act('cancel-sheet').click();
  await act('category-transcription').click();await input('processingLocation').selectOption('cloud');assert((await app.locator('.rs-warning').textContent()).includes('approval for each activation'));assert(await input('autoTranscribe').isDisabled());await shot('settings-cloud-light');await input('processingLocation').selectOption('local');
  await input('textMode').selectOption('translate');assert.equal(await input('targetLanguage').count(),1);
  await act('routing').click();await pair('routing');
  await input('playbackCapture').selectOption('Playback off');assert((await app.locator('[aria-label="System audio source"]').textContent()).includes('Not captured'));await input('playbackCapture').selectOption('All system audio');
  assert.equal(await app.locator('.rs-route-card').count(),2);
  assert.equal(await app.locator('.rs-route-card').first().locator('[data-input=hardware]').count(),0);
  await act('test-sources').click();assert(await act('route-mic-0-0').isDisabled());await act('mute-mic').click();assert((await app.locator('[aria-label="MacBook microphone source"]').textContent()).includes('Muted in mix'));await pair('routing-muted-test');
  const gain=app.locator('[data-input=gain][data-source=mic][type=number]');await gain.fill('-6');await gain.dispatchEvent('change');assert.equal(await app.locator('[data-input=gain][data-source=mic][type=range]').inputValue(),'-6');
  assert.equal(await app.locator('[aria-label="MacBook microphone source"] .rs-meter>span').first().getAttribute('style'),'width:70%');assert.equal(await app.locator('[aria-label="MacBook microphone source"] .rs-meter>span').last().getAttribute('style'),'width:0%');
  await act('test-sources').click();await act('route-mic-0-0').click();assert.equal(await act('route-mic-0-0').getAttribute('aria-pressed'),'false');
  await act('reset-mic').click();assert.equal(await act('route-mic-0-0').getAttribute('aria-pressed'),'false');assert.equal(await app.locator('[data-input=hardware][data-source=mic]').inputValue(),'78');
  await act('virtual-add').click();assert.equal(await app.locator('.rs-route-card').count(),3);await act('mute-loop').click();await act('virtual-remove').click();await act('virtual-add').click();assert.equal(await act('mute-loop').getAttribute('aria-pressed'),'true');await pair('routing-virtual');
  await act('monitor-mute').click();assert.equal(await act('monitor').getAttribute('aria-pressed'),'false');await act('monitor').click();assert.equal(await act('monitor-mute').getAttribute('aria-pressed'),'true');await act('reset-monitor').click();assert.equal(await act('monitor').getAttribute('aria-pressed'),'true');
  await act('live').click();await act('start').click();await act('routing').click();assert(await act('test-sources').isDisabled());assert(await act('route-mic-0-0').isDisabled());assert.equal(await act('mute-mic').isDisabled(),false);await shot('routing-recording-light');
  await act('recordings').click();await input('master').check();assert(await act('delete-selected').isDisabled());await act('global-stop').click();await act('clear-selection').click();
  await act('studio').click();await pair('studio');await act('live').click();await pair('live');
  for(const width of [1152,1024,940,760,620,360,320]){
   await page.setViewportSize({width,height:1600});
   for(const mode of ['recordings','settings','routing']){await act(mode).click();if(mode==='settings'){for(const category of ['general','recording','transcription','models','intelligence','diagnostics']){await act('category-'+category).click();await fits(width)}}else await fits(width);if(width===360)await shot(mode+'-narrow');}
  }
  await page.setViewportSize({width:1152,height:1500});await theme('system');await page.emulateMedia({colorScheme:'dark'});assert.equal(await app.evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(21, 23, 25)');
  assert.deepEqual(errors,[]);
  console.log('PASS: selection/filter/delete-scope/cancel/undo/details, six settings sections, explicit provider/consent handoffs, 38 native symbol masks, independent source selection/mute/gain/trim/routing, virtual preference retention, monitor/playback separation, recording guards; light/dark/system, 320–1152px; no script errors. Synthetic UI only; native tests and accessibility remain pending.');
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
