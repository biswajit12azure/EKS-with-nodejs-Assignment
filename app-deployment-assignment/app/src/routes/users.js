const express = require('express');
const router = express.Router();

const users = [
  { id: 1, name: 'Alice', role: 'admin' },
  { id: 2, name: 'Bob', role: 'developer' },
  { id: 3, name: 'Carol', role: 'viewer' },
];

router.get('/', (req, res) => {
  res.status(200).json({ users });
});

router.get('/:id', (req, res) => {
  const user = users.find((u) => u.id === parseInt(req.params.id));
  if (!user) {
    return res.status(404).json({ error: 'User not found' });
  }
  res.status(200).json({ user });
});

module.exports = router;
