const express = require('express');
const mongoose = require('mongoose');
const app = express();

// Middleware
app.use(express.json());

// Environment variables with defaults
const PORT = process.env.PORT || 3000;
const MONGO_URI = process.env.MONGO_URI || 'mongodb://mongo:27017/taskmanager';
const APP_VERSION = process.env.APP_VERSION || 'blue';

// MongoDB Connection with retry logic
let isDbConnected = false;

const connectDB = async () => {
  try {
    await mongoose.connect(MONGO_URI, {
      serverSelectionTimeoutMS: 5000,
      socketTimeoutMS: 45000,
    });
    isDbConnected = true;
    console.log(`✅ MongoDB connected successfully - Version: ${APP_VERSION}`);
  } catch (error) {
    isDbConnected = false;
    console.error('❌ MongoDB connection error:', error.message);
    // Retry connection after 5 seconds
    setTimeout(connectDB, 5000);
  }
};

// Handle MongoDB disconnection
mongoose.connection.on('disconnected', () => {
  isDbConnected = false;
  console.warn('⚠️  MongoDB disconnected. Attempting to reconnect...');
});

mongoose.connection.on('error', (err) => {
  isDbConnected = false;
  console.error('❌ MongoDB error:', err);
});

// Task Schema
const taskSchema = new mongoose.Schema({
  title: {
    type: String,
    required: true,
    trim: true,
  },
  description: {
    type: String,
    trim: true,
  },
  status: {
    type: String,
    enum: ['pending', 'in-progress', 'completed'],
    default: 'pending',
  },
  priority: {
    type: String,
    enum: ['low', 'medium', 'high'],
    default: 'medium',
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
  updatedAt: {
    type: Date,
    default: Date.now,
  },
});

const Task = mongoose.model('Task', taskSchema);

// ==================== HEALTH CHECK ENDPOINT ====================
// This is CRITICAL for zero-downtime deployments
app.get('/health', async (req, res) => {
  const healthStatus = {
    status: 'healthy',
    version: APP_VERSION,
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    database: isDbConnected ? 'connected' : 'disconnected',
  };

  // Return 503 if database is not connected
  if (!isDbConnected) {
    healthStatus.status = 'unhealthy';
    return res.status(503).json(healthStatus);
  }

  res.status(200).json(healthStatus);
});

// ==================== API ROUTES ====================

// Welcome route
app.get('/', (req, res) => {
  res.json({
    message: 'Task Manager API - Zero Downtime Deployment Demo',
    version: APP_VERSION,
    endpoints: {
      health: '/health',
      tasks: {
        getAll: 'GET /api/tasks',
        getOne: 'GET /api/tasks/:id',
        create: 'POST /api/tasks',
        update: 'PUT /api/tasks/:id',
        delete: 'DELETE /api/tasks/:id',
      },
    },
  });
});

// GET all tasks
app.get('/api/tasks', async (req, res) => {
  try {
    const tasks = await Task.find().sort({ createdAt: -1 });
    res.json({
      success: true,
      count: tasks.length,
      data: tasks,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Server Error',
      message: error.message,
    });
  }
});

// GET single task
app.get('/api/tasks/:id', async (req, res) => {
  try {
    const task = await Task.findById(req.params.id);
    
    if (!task) {
      return res.status(404).json({
        success: false,
        error: 'Task not found',
      });
    }

    res.json({
      success: true,
      data: task,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Server Error',
      message: error.message,
    });
  }
});

// CREATE task
app.post('/api/tasks', async (req, res) => {
  try {
    const { title, description, status, priority } = req.body;

    if (!title) {
      return res.status(400).json({
        success: false,
        error: 'Please provide a task title',
      });
    }

    const task = await Task.create({
      title,
      description,
      status,
      priority,
    });

    res.status(201).json({
      success: true,
      data: task,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Server Error',
      message: error.message,
    });
  }
});

// UPDATE task
app.put('/api/tasks/:id', async (req, res) => {
  try {
    const task = await Task.findByIdAndUpdate(
      req.params.id,
      { ...req.body, updatedAt: Date.now() },
      { new: true, runValidators: true }
    );

    if (!task) {
      return res.status(404).json({
        success: false,
        error: 'Task not found',
      });
    }

    res.json({
      success: true,
      data: task,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Server Error',
      message: error.message,
    });
  }
});

// DELETE task
app.delete('/api/tasks/:id', async (req, res) => {
  try {
    const task = await Task.findByIdAndDelete(req.params.id);

    if (!task) {
      return res.status(404).json({
        success: false,
        error: 'Task not found',
      });
    }

    res.json({
      success: true,
      data: {},
      message: 'Task deleted successfully',
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Server Error',
      message: error.message,
    });
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: 'Route not found',
  });
});

// Global error handler
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    success: false,
    error: 'Internal Server Error',
    message: err.message,
  });
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('🛑 SIGTERM received. Closing HTTP server...');
  await mongoose.connection.close();
  process.exit(0);
});

// Start server
const startServer = async () => {
  await connectDB();
  
  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 Server running on port ${PORT}`);
    console.log(`📦 Version: ${APP_VERSION}`);
    console.log(`🔗 Health check: http://localhost:${PORT}/health`);
  });

  server.on('error', (error) => {
    console.error('❌ Server error:', error);
    process.exit(1);
  });
};

startServer();
