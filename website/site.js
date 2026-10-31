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
