#include "native_memory_stats.h"

#include <cassert>
#include <chrono>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

using media_kit_memory::OutputLifetime;
using media_kit_memory::Registry;
using media_kit_memory::Resource;
using media_kit_memory::ResourceRecord;

int main() {
  auto& registry = Registry::Instance();
  {
    OutputLifetime first;
    OutputLifetime second;
    first.Bind(7, 1);
    second.Bind(8, 2);
    ResourceRecord texture(Resource::texture, first.id());
    texture.Set(2, 4096);
    texture.Set(2, 8192);
    first.BeginRelease();
    first.BeginRelease();
    registry.PendingTextureUnregistration(1, first.id());
    registry.Change(Resource::texture_registration, 1, 0, first.id());
    const auto snapshot = registry.ReadAll();
    assert(snapshot.totals.releasing_outputs == 1);
    assert(snapshot.totals.pending_texture_unregistrations == 1);
    assert(snapshot.ownership.owners[0].runtime_id == 7);
    assert(snapshot.ownership.owners[1].runtime_id == 8);
    const auto& own = snapshot.ownership.owners[0];
    assert(own.resources[static_cast<size_t>(Resource::texture)].created == 2);
    assert(own.resources[static_cast<size_t>(Resource::texture)].estimated_bytes == 8192);
    assert(snapshot.ownership.owners[1].resources[static_cast<size_t>(Resource::texture)].count == 0);
    first.Bind(7, 3);
    assert(registry.ReadOwners().owners[0].load_id == 3);
    registry.PendingTextureUnregistration(-1, first.id());
    registry.Change(Resource::texture_registration, -1, 0, first.id());
  }
  try {
    OutputLifetime lifetime;
    ResourceRecord partial(Resource::texture, lifetime.id());
    partial.Set(1, 1024);
    throw std::runtime_error("partial creation");
  } catch (const std::runtime_error&) {
  }
  {
    std::vector<std::unique_ptr<OutputLifetime>> owners;
    for (int index = 0; index < 10; ++index) owners.push_back(std::make_unique<OutputLifetime>());
    assert(registry.ReadOwners().omitted_owners == 2);
    owners.erase(owners.begin());
    owners.push_back(std::make_unique<OutputLifetime>());
    assert(registry.ReadOwners().omitted_owners == 2);
  }
  const auto start = std::chrono::steady_clock::now();
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([&registry]() {
      for (int index = 0; index < 10000; ++index) {
        OutputLifetime lifetime;
        ResourceRecord texture(Resource::texture, lifetime.id());
        texture.Set(2, 4096);
        lifetime.Bind(index + 1, 1);
        if (index % 100 == 0) registry.ReadAll();
      }
    });
  }
  for (auto& worker : workers) worker.join();
  const auto final = registry.ReadAll();
  for (const auto& resource : final.totals.resources) {
    assert(resource.count == 0);
    assert(resource.estimated_bytes == 0);
    assert(resource.created == resource.released);
  }
  for (const auto& owner : final.ownership.owners) assert(owner.id == 0);
  assert(final.ownership.omitted_owners == 0);
  assert(final.totals.releasing_outputs == 0);
  assert(final.totals.pending_texture_unregistrations == 0);
  const auto milliseconds = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - start).count();
  std::cout << "ownership, partial creation, overflow, reuse, concurrency: passed; "
            << "40000 output lifetimes in " << milliseconds << " ms\n";
}
