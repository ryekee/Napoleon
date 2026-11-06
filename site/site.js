'use strict';

const languageMenu = document.querySelector('.language-menu');
document.addEventListener('click', event => {
  if (!languageMenu.contains(event.target)) languageMenu.open = false;
});
languageMenu.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    languageMenu.open = false;
    languageMenu.querySelector('summary').focus();
  }
});
