### Installing dependencies
* bundle && cd web && npm install

### Production
* cd web && npm run build && cd ../ && rake remote

### Development
In one terminal:
* rake local

In another:
* cd web && node_modules/vite/bin/vite.js

Then open `http://localhost:5568`
