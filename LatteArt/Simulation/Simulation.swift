// Simulation layer.
//
// Consumes `PourSource`/`PourSample` from Sensor (push-based) and turns each
// pour observation into surface behaviour, publishing state for the UI. It never
// knows whether the input came from AprilTag, touch, or the scripted demo.
//
// Pieces:
//   - MetalContext          shared device/queue/library
//   - Fluid.metal           Stam Stable-Fluids kernels + cup-quad render pair
//   - FluidSimulation       the 256² solver (ping-pong velocity/dye/pressure)
//   - PourPhysics           flow curve + Froude float-vs-sink gate + contract adapter
//   - LevelModel            cup fill integration
//   - SimulationController  glue: sample → physics → splat → step; publishes state
//   - FluidBlitter          MTKView delegate; composites the dye disc via CupPose
//   - SimulationDebugView   temporary dev harness (replaced by Presentation)
//
// Physics decisions (the tilt→flow curve, the float-vs-sink Froude gate) live
// HERE, not in Sensor. Coordinates are `CupSpace`: cup center (0.5,0.5), rim =
// radius 0.5, UV y-down; the sim texture maps 1:1 onto that square.
