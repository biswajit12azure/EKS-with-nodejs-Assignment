const express = require('express');
const healthRouter = require('./routes/health');
const usersRouter = require('./routes/users');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.use('/health', healthRouter);
app.use('/users', usersRouter);

app.get('/', (req, res) => {
  res.json({ message: 'Hello World from EKS!', version: '1.0.0' });
});

// Only start listening when run directly (not when imported by tests)
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

module.exports = app;
