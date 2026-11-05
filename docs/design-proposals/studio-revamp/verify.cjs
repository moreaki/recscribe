const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
(async()=>{
 assert(process.env.RECSCRIBE_RUN_DIR,'Run via scripts/work-artifacts.py');
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const page=await browser.newPage({viewport:{width:1152,height:1080},deviceScaleFactor:1.5,colorScheme:'light'});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const file=pathToFileURL(path.join(__dirname,'studio.html')).href;
 async function reset(){await page.goto(file);await page.evaluate(()=>localStorage.clear());await page.reload();await page.frameLocator('iframe').locator('.rs-app').first().waitFor();}
 await reset();
 const frame=page.frameLocator('iframe');
 const focus=frame.locator('[data-variant="Focus"] .rs-app');
 const canvas=frame.locator('[data-variant="Canvas"] .rs-app');
 const action=(name,scope=focus)=>scope.locator(`[data-action="${name}"]`).first();
 async function shot(name,scope=focus){await scope.screenshot({path:path.join(process.env.RECSCRIBE_RUN_DIR,name+'.png')});}
 async function fits(scope,width){
  const overflow=await scope.evaluate(el=>{
   const r=el.getBoundingClientRect();
   return [...el.querySelectorAll('button,input,select,h1,p')].filter(x=>x.getClientRects().length).filter(x=>{const b=x.getBoundingClientRect();return b.width>0&&(b.left<r.left-1||b.right>r.right+1)}).map(x=>x.textContent.slice(0,60));
  });assert.deepEqual(overflow,[],`Overflow at ${width}`);
 }
 await shot('focus-reading');
 await action('review-source').click();
 assert.equal(await focus.locator('[aria-label="Review inspector"]').count(),1);
 assert.equal(await focus.locator('.rs-source').count(),2);
 assert((await focus.textContent()).includes('22.180–24.320'));
 assert(await action('close').evaluate(el=>el===el.ownerDocument.activeElement));
 await shot('focus-review');
 await action('listen').click();assert.equal(await focus.locator('[data-input=position]').inputValue(),'22');
 assert((await action('play').textContent()).includes('Pause'));
 await action('check').click();assert.equal(await focus.locator('.rs-count').textContent(),'1');
 await action('next').click();assert((await focus.locator('.rs-inspector').textContent()).includes('Translation was not run'));
 await shot('focus-processing-note');
 await action('check').click();assert.equal(await focus.locator('.rs-count').textContent(),'0');
 await action('all-items').click();await action('item-0').click();await action('reopen').click();assert.equal(await focus.locator('.rs-count').textContent(),'1');
 await action('details').click();assert.equal(await focus.locator('[aria-label="Recording details"]').count(),1);
 await focus.locator('summary').click();assert((await focus.locator('pre').textContent()).includes('confidence_unavailable'));
 await shot('focus-details');
 await page.keyboard.press('Escape');assert.equal(await focus.locator('.rs-inspector').count(),0);
 await action('summary').click();assert((await focus.locator('.rs-document').textContent()).includes('Community priorities'));await shot('focus-summary');
 await action('summary-last-source').click();assert.equal(await focus.locator('[data-input=position]').inputValue(),'39');
 await action('channels').click();assert.equal(await focus.locator('.rs-source').count(),10);await action('channels').click();
 await action('export').click();await action('copy-markdown').click();assert((await focus.locator('[role=status]').textContent()).includes('simulated export'));
 await action('live').click();assert((await focus.textContent()).includes('Start a new session'));await shot('live-ready');
 await focus.locator('[data-input=liveText]').uncheck();await action('start').click();assert((await focus.textContent()).includes('Live transcription is off'));
 await action('studio').click();assert((await focus.locator('h1').textContent()).includes('Community interview'));
 assert.equal(await focus.locator('.rs-live-banner').count(),1);await action('process').click();assert(await action('retry').isDisabled());await action('close-menu').click();await shot('studio-while-recording');
 await action('live').click();await action('stop').click();assert((await focus.textContent()).includes('Recording saved'));await shot('live-saved');
 await action('finish').click();assert((await focus.textContent()).includes('Create a final transcript'));assert.equal(await focus.locator('.rs-paragraph').count(),0);await shot('studio-handoff');
 await action('create-final').click();assert.equal(await focus.locator('.rs-paragraph').count(),5);
 await action('live').click();await action('new-session').click();await focus.locator('[data-input=liveText]').check();await action('start').click();await shot('live-recording');
 await action('studio').click();await action('review').click();
 await action('global-stop').click();assert((await focus.locator('h1').textContent()).includes('New session'));assert.equal(await focus.locator('.rs-live-banner').count(),0);
 await reset();await action('review').click();
 await page.emulateMedia({colorScheme:'dark'});await shot('focus-review-dark');await page.emulateMedia({colorScheme:'light'});
 for(const width of [1152,1024,940,760,620,360,320]){
  await page.setViewportSize({width,height:1500});await fits(focus,width);
  if(width===940)await shot('focus-review-compact');if(width===360)await shot('focus-review-narrow');
 }
 await page.setViewportSize({width:1152,height:1200});
 // Inspect alternate layout directly; the supplied runtime owns the variant picker.
 await frame.locator('[data-variant="Focus"]').evaluate(el=>el.hidden=true);
 await frame.locator('[data-variant="Canvas"]').evaluate(el=>el.hidden=false);
 await shot('canvas-reading',canvas);await action('review',canvas).click();await shot('canvas-review',canvas);
 for(const width of [1024,620,360,320]){await page.setViewportSize({width,height:1500});await fits(canvas,width)}
 assert.deepEqual(errors,[]);await browser.close();
 console.log('PASS: synthetic Review/details/technical disclosure, counts/check/reopen, source seek, summary links, channel view, export feedback, independent Live lifecycle, retained Studio selection, capture processing guard, explicit empty final-transcript handoff; light/dark; 320–1152 px bounds; no script errors. Native behavior and VoiceOver untested.');
})().catch(error=>{console.error(error);process.exit(1)});
