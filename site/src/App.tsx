import { MotionConfig } from "motion/react";
import { Builder } from "./components/Builder";
import { Demo } from "./components/Demo";
import { Footer } from "./components/Footer";
import { Hero } from "./components/Hero";
import { Install } from "./components/Install";
import { Nav } from "./components/Nav";
import { PolicyTable } from "./components/PolicyTable";
import { Safety } from "./components/Safety";

export default function App() {
  return (
    <MotionConfig reducedMotion="user">
      <Nav />
      <main id="main">
        <Hero />
        <Builder />
        <Demo />
        <Safety />
        <PolicyTable />
        <Install />
      </main>
      <Footer />
    </MotionConfig>
  );
}
