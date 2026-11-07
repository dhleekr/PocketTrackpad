(() => {
  const buttons = [...document.querySelectorAll('[data-language]')];
  const blocks = [...document.querySelectorAll('[data-copy]')];
  function setLanguage(language) {
    document.documentElement.lang = language;
    blocks.forEach(block => block.classList.toggle('hide', block.dataset.copy !== language));
    buttons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.language === language)));
    try { localStorage.setItem('pocket-language', language); } catch (_) {}
  }
  buttons.forEach(button => button.addEventListener('click', () => setLanguage(button.dataset.language)));
  let saved; try { saved = localStorage.getItem('pocket-language'); } catch (_) {}
  setLanguage(saved === 'ko' ? 'ko' : 'en');
})();

// A small, self-contained gesture illustration. The actual app screens stay unaltered.
(() => {
  const experience = document.querySelector('.gesture-experience');
  if (!experience) return;
  const buttons = [...experience.querySelectorAll('[data-demo]')];
  buttons.forEach(button => button.addEventListener('click', () => {
    const gesture = button.dataset.demo;
    experience.dataset.gesture = gesture;
    buttons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    experience.querySelectorAll('[data-demo-description]').forEach(item => {
      item.hidden = item.dataset.demoDescription !== gesture;
    });
    const descriptions = {scroll:'Illustration of a two-finger scroll gesture',zoom:'Illustration of a two-finger pinch gesture',spaces:'Illustration of a three-finger swipe gesture'};
    experience.querySelector('.gesture-demo').setAttribute('aria-label', descriptions[gesture]);
  }));
})();
