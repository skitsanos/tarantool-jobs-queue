# Tarantool Jobs Queue with REST API

> This project implements a jobs queue system using Tarantool, a high-performance in-memory NoSQL database combined with
> a powerful Lua application server. The system provides a RESTful API interface for managing and processing jobs,
> allowing for easy integration with various applications and services.

## Features:

- **Job Management**: Add jobs to the queue, fetch them for processing, view job details, and remove them once
  processed.
- **RESTful API**: Interact with the jobs queue using standard HTTP methods. Endpoints include:
    - `POST /jobs`: Add a new job to the queue.
    - `GET /jobs`: Retrieve a paginated list of jobs.
    - `GET /jobs/:id`: Fetch details of a specific job by its ID.
    - `DELETE /jobs/:id`: Remove a job from the queue.
- **Pagination**: Efficiently browse through the list of jobs with limit and offset parameters.
- **Modular Design**: Job management logic is encapsulated in a separate module, ensuring clean and maintainable code.
- **Docker Integration**: Easily set up and run the system using Docker Compose.

Whether you're looking to process tasks asynchronously, distribute workloads, or simply manage a list of tasks, this
Tarantool-based message queue system offers a robust and scalable solution.
