// ===========================
// Theme Switcher
// ===========================
const themeButtons = document.querySelectorAll('.theme-btn');
const html = document.documentElement;

// Load saved theme or default to blue
const savedTheme = localStorage.getItem('theme') || 'blue';
html.setAttribute('data-theme', savedTheme);
updateActiveButton(savedTheme);

themeButtons.forEach(btn => {
  btn.addEventListener('click', () => {
    const theme = btn.getAttribute('data-theme');
    html.setAttribute('data-theme', theme);
    localStorage.setItem('theme', theme);
    updateActiveButton(theme);
  });
});

function updateActiveButton(theme) {
  themeButtons.forEach(btn => {
    btn.classList.toggle('active', btn.getAttribute('data-theme') === theme);
  });
}

// ===========================
// Navbar Scroll Effect
// ===========================
const navbar = document.getElementById('navbar');

window.addEventListener('scroll', () => {
  if (window.scrollY > 50) {
    navbar.classList.add('scrolled');
  } else {
    navbar.classList.remove('scrolled');
  }
});

// ===========================
// Mobile Menu Toggle
// ===========================
const navToggle = document.getElementById('navToggle');
const navLinks = document.getElementById('navLinks');

navToggle.addEventListener('click', () => {
  navToggle.classList.toggle('active');
  navLinks.classList.toggle('open');
});

// Close menu on link click
navLinks.querySelectorAll('.nav-link').forEach(link => {
  link.addEventListener('click', () => {
    navToggle.classList.remove('active');
    navLinks.classList.remove('open');
  });
});

// ===========================
// Smooth Scroll for Anchor Links
// ===========================
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
  anchor.addEventListener('click', function (e) {
    e.preventDefault();
    const target = document.querySelector(this.getAttribute('href'));
    if (target) {
      const offset = 80;
      const position = target.getBoundingClientRect().top + window.scrollY - offset;
      window.scrollTo({ top: position, behavior: 'smooth' });
    }
  });
});

// ===========================
// FAQ Accordion
// ===========================
document.querySelectorAll('.faq-item__trigger').forEach(trigger => {
  trigger.addEventListener('click', () => {
    const item = trigger.parentElement;
    const isActive = item.classList.contains('active');

    // Close all items
    document.querySelectorAll('.faq-item').forEach(faqItem => {
      faqItem.classList.remove('active');
    });

    // Toggle clicked item
    if (!isActive) {
      item.classList.add('active');
    }
  });
});

// ===========================
// Scroll Reveal Animation
// ===========================
const revealElements = document.querySelectorAll('[data-reveal]');

const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry, index) => {
    if (entry.isIntersecting) {
      // Stagger the animation for grid items
      const delay = entry.target.closest('.features__grid, .platforms__grid, .faq__list')
        ? Array.from(entry.target.parentElement.children).indexOf(entry.target) * 100
        : 0;

      setTimeout(() => {
        entry.target.classList.add('revealed');
      }, delay);

      revealObserver.unobserve(entry.target);
    }
  });
}, {
  threshold: 0.1,
  rootMargin: '0px 0px -50px 0px'
});

revealElements.forEach(el => revealObserver.observe(el));

// ===========================
// Active Nav Link on Scroll
// ===========================
const sections = document.querySelectorAll('section[id]');

window.addEventListener('scroll', () => {
  const scrollPos = window.scrollY + 100;

  sections.forEach(section => {
    const top = section.offsetTop;
    const height = section.offsetHeight;
    const id = section.getAttribute('id');

    if (scrollPos >= top && scrollPos < top + height) {
      document.querySelectorAll('.nav-link').forEach(link => {
        link.classList.remove('active');
        if (link.getAttribute('href') === `#${id}`) {
          link.classList.add('active');
        }
      });
    }
  });
});

// ===========================
// Animate Stats on Scroll
// ===========================
const animateCounter = (element, target, suffix = '%') => {
  let current = 0;
  const increment = target / 40;
  const timer = setInterval(() => {
    current += increment;
    if (current >= target) {
      current = target;
      clearInterval(timer);
    }
    element.textContent = Math.floor(current) + suffix;
  }, 30);
};

const statValues = document.querySelectorAll('.stat-value');
let statsAnimated = false;

const statsObserver = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting && !statsAnimated) {
      statsAnimated = true;
      statValues.forEach(el => {
        const value = parseInt(el.textContent);
        animateCounter(el, value);
      });
    }
  });
}, { threshold: 0.5 });

const dashboard = document.querySelector('.dashboard-mockup');
if (dashboard) {
  statsObserver.observe(dashboard);
}

// ===========================
// Animate Progress Bars
// ===========================
const barFills = document.querySelectorAll('.bar-fill');

const barObserver = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      const fill = entry.target;
      const width = fill.style.width;
      fill.style.width = '0%';
      setTimeout(() => {
        fill.style.width = width;
      }, 200);
      barObserver.unobserve(fill);
    }
  });
}, { threshold: 0.5 });

barFills.forEach(bar => barObserver.observe(bar));
