#include "db.h"
#include <stdlib.h>
#include <algorithm>

using namespace std;

int nMinimumHeight = 0;

void CAddrInfo::Update(bool good) {
  uint32_t now = time(NULL);
  if (ourLastTry == 0)
    ourLastTry = now - MIN_RETRY;
  int age = now - ourLastTry;
  lastTry = now;
  ourLastTry = now;
  total++;
  if (good)
  {
    success++;
    ourLastSuccess = now;
  }
  stat2H.Update(good, age, 3600*2);
  stat8H.Update(good, age, 3600*8);
  stat1D.Update(good, age, 3600*24);
  stat1W.Update(good, age, 3600*24*7);
  stat1M.Update(good, age, 3600*24*30);
  int ign = GetIgnoreTime();
  if (ign && (ignoreTill==0 || ignoreTill < ign+now)) ignoreTill = ign+now;
//  printf("%s: got %s result: success=%i/%i; 2H:%.2f%%-%.2f%%(%.2f) 8H:%.2f%%-%.2f%%(%.2f) 1D:%.2f%%-%.2f%%(%.2f) 1W:%.2f%%-%.2f%%(%.2f) \n", ToString(ip).c_str(), good ? "good" : "bad", success, total, 
//  100.0 * stat2H.reliability, 100.0 * (stat2H.reliability + 1.0 - stat2H.weight), stat2H.count,
//  100.0 * stat8H.reliability, 100.0 * (stat8H.reliability + 1.0 - stat8H.weight), stat8H.count,
//  100.0 * stat1D.reliability, 100.0 * (stat1D.reliability + 1.0 - stat1D.weight), stat1D.count,
//  100.0 * stat1W.reliability, 100.0 * (stat1W.reliability + 1.0 - stat1W.weight), stat1W.count);
}

bool CAddrDb::Get_(CServiceResult &ip, int &wait) {
  int64 now = time(NULL);
  int cont = 0;
  // Cap discovery at half the crawl budget.
  // This chain shares its port with a much larger network, so address gossip
  // delivers an effectively unbounded stream of never-tried addresses. If
  // discovery is allowed to dominate the crawl budget, already-known nodes are
  // not re-polled often enough: stat2H has tau=2h and IsGood() requires
  // count > 2, so a node must be re-polled roughly every 83 minutes or its
  // stat2H.count decays below the threshold and it stops being served even
  // though it is perfectly reachable. Weighting never-tried addresses at no
  // more than the number of known nodes bounds them to at most half of tot.
  // Cold-start exception: when nothing is known yet (ourId empty) use the full
  // never-tried pool, otherwise a fresh seeder could never crawl its bootstrap
  // addresses.
  int nUnk = static_cast<int>(unkId.size());
  int nOur = static_cast<int>(ourId.size());
  int unkWeight = (nOur == 0) ? nUnk : (nUnk < nOur ? nUnk : nOur);
  int tot = unkWeight + nOur;
  if (tot == 0) {
    wait = 5;
    return false;
  }
  do {
    int ret;
    // Fork-priority slice.
    // Only a few hundred nodes advertise NODE_BLAKE2B, and they sit inside a
    // quarter-million-entry ourId FIFO: a full ourId cycle takes ~2.3 hours,
    // while stat2H (tau=2h, IsGood() requires count > 2) needs a poll roughly
    // every 83 minutes. forkId rotates those nodes independently so they keep
    // being served. See FORK_CRAWL_PCT in db.h for why the slice is 5%.
    // forkId and ourId are a partition, not an overlay: a fork node rotates in
    // forkId instead of ourId, so a pop here is still balanced by exactly one
    // push in the Good_/Bad_/Skipped_ callback (see Requeue_).
    if (!forkId.empty() && rand() % 100 < FORK_CRAWL_PCT) {
      int forkRet = forkId.front();
      forkId.pop_front();
      // Guard before any idToInfo[] use: operator[] would default-construct a
      // phantom entry for an id that Bad_() has already banned away.
      if (idToInfo.count(forkRet) == 0) {
        // Node was banned and its CAddrInfo erased; drop it and fall through.
      } else if (now - idToInfo[forkRet].ourLastTry < MIN_RETRY) {
        // Unlike the ourId path above, do not return false here. ourId is a
        // strict FIFO, so its front being too recent means the whole queue is
        // too recent; forkId is only a 5% slice, and throwing away the entire
        // crawl slot because one fork node is not due yet would waste more
        // budget than the starvation this queue exists to fix. Re-append and
        // fall through to normal selection.
        forkId.push_back(forkRet);
      } else {
        // Do not re-append here: the pop above is balanced by the Requeue_
        // call in the mandatory Good_/Bad_/Skipped_ callback, exactly as the
        // ourId path below is.
        ret = forkRet;
        ip.service = idToInfo[ret].ip;
        ip.ourLastSuccess = idToInfo[ret].ourLastSuccess;
        break;
      }
    }
    int rnd = rand() % tot;
    if (rnd < unkWeight) {
      set<int>::iterator it = unkId.end(); it--;
      ret = *it;
      unkId.erase(it);
    } else {
      ret = ourId.front();
      if (time(NULL) - idToInfo[ret].ourLastTry < MIN_RETRY) return false;
      ourId.pop_front();
    }
    if (idToInfo[ret].ignoreTill && idToInfo[ret].ignoreTill < now) {
      ourId.push_back(ret);
      idToInfo[ret].ourLastTry = now;
    } else {
      ip.service = idToInfo[ret].ip;
      ip.ourLastSuccess = idToInfo[ret].ourLastSuccess;
      break;
    }
  } while(1);
  nDirty++;
  return true;
}

int CAddrDb::Lookup_(const CService &ip) {
  if (ipToId.count(ip))
    return ipToId[ip];
  return -1;
}

// Return an id to exactly one rotation queue, balancing the single pop that
// Get_ performed. Fork nodes rotate in forkId, everything else in ourId.
void CAddrDb::Requeue_(int id) {
  std::map<int, CAddrInfo>::iterator it = idToInfo.find(id);
  // success > 0 is what makes the service bits trustworthy. Add_() seeds
  // services from ADDR gossip for addresses never crawled, so an address can
  // claim NODE_BLAKE2B without anyone having reached it — and Bad_() requeues
  // those too. Enrolling on the rumour alone let forkId fill with dead
  // addresses (964 entries against a real population of 391, still climbing),
  // diluting the priority slice it exists to protect. After a successful
  // crawl the bits came from the peer's own VERSION via Good_(), so they can
  // be trusted; Good_() calls Update(true) before requeuing, so a genuine
  // fork node still enrols on its very first success.
  if (it != idToInfo.end() && it->second.success > 0 &&
      (it->second.services & NODE_BLAKE2B)) {
    // Already queued means this crawl came from a leftover ourId entry for a
    // node since enrolled in forkId. Dropping it here is how those stale
    // duplicates drain away; forkId still holds the node, so it is not lost.
    if (std::find(forkId.begin(), forkId.end(), id) == forkId.end())
      forkId.push_back(id);
  } else {
    // Not a fork node — or, defensively, an id with no idToInfo entry. The
    // latter cannot happen via today's callers (Good_/Bad_/Skipped_ all
    // return early when Lookup_ fails), but is left here rather than
    // asserted so a future caller degrades to ourId instead of crashing.
    ourId.push_back(id);
  }
}

void CAddrDb::Good_(const CService &addr, int clientV, std::string clientSV, int blocks, uint64_t services) {
  int id = Lookup_(addr);
  if (id == -1) return;
  unkId.erase(id);
  banned.erase(addr);
  CAddrInfo &info = idToInfo[id];
  info.clientVersion = clientV;
  info.clientSubVersion = clientSV;
  info.blocks = blocks;
  info.services = services;
  info.Update(true);
  if (info.IsGood() && goodId.count(id)==0) {
    goodId.insert(id);
//    printf("%s: good; %i good nodes now\n", ToString(addr).c_str(), (int)goodId.size());
  }
  nDirty++;
  Requeue_(id);
}

void CAddrDb::Bad_(const CService &addr, int ban)
{
  int id = Lookup_(addr);
  if (id == -1) return;
  unkId.erase(id);
  CAddrInfo &info = idToInfo[id];
  info.Update(false);
  uint32_t now = time(NULL);
  int ter = info.GetBanTime();
  if (ter) {
//    printf("%s: terrible\n", ToString(addr).c_str());
    if (ban < ter) ban = ter;
  }
  if (ban > 0) {
//    printf("%s: ban for %i seconds\n", ToString(addr).c_str(), ban);
    banned[info.ip] = ban + now;
    ipToId.erase(info.ip);
    goodId.erase(id);
    idToInfo.erase(id);
    // The CAddrInfo is gone, so this id must not stay selectable in the fork
    // rotation queue.
    forkId.erase(std::remove(forkId.begin(), forkId.end(), id), forkId.end());
  } else {
    if (/*!info.IsGood() && */ goodId.count(id)==1) {
      goodId.erase(id);
//      printf("%s: not good; %i good nodes left\n", ToString(addr).c_str(), (int)goodId.size());
    }
    Requeue_(id);
  }
  nDirty++;
}

void CAddrDb::Skipped_(const CService &addr)
{
  int id = Lookup_(addr);
  if (id == -1) return;
  unkId.erase(id);
  Requeue_(id);
//  printf("%s: skipped\n", ToString(addr).c_str());
  nDirty++;
}


void CAddrDb::Add_(const CAddress &addr, bool force) {
  if (!force && !addr.IsRoutable())
    return;
  CService ipp(addr);
  if (banned.count(ipp)) {
    time_t bantime = banned[ipp];
    if (force || (bantime < time(NULL) && addr.nTime > bantime))
      banned.erase(ipp);
    else
      return;
  }
  if (ipToId.count(ipp)) {
    CAddrInfo &ai = idToInfo[ipToId[ipp]];
    if (addr.nTime > ai.lastTry) ai.lastTry = addr.nTime;
    // Do not update ai.nServices (data from VERSION from the peer itself is better than random ADDR rumours).
    if (force) {
      ai.ignoreTill = 0;
    }
    return;
  }
  CAddrInfo ai;
  ai.ip = ipp;
  ai.services = addr.nServices;
  ai.lastTry = addr.nTime;
  ai.ourLastTry = 0;
  ai.total = 0;
  ai.success = 0;
  int id = nId++;
  idToInfo[id] = ai;
  ipToId[ipp] = id;
//  printf("%s: added\n", ToString(ipp).c_str(), ipToId[ipp]);
  unkId.insert(id);
  nDirty++;
}

void CAddrDb::GetIPs_(set<CNetAddr>& ips, uint64_t requestedFlags, int max, const bool* nets) {
  if (goodId.size() == 0) {
    int id = -1;
    if (ourId.size() == 0) {
      if (unkId.size() == 0) return;
      id = *unkId.begin();
    } else {
      id = *ourId.begin();
    }
    if (id >= 0 && (idToInfo[id].services & requestedFlags) == requestedFlags) {
      ips.insert(idToInfo[id].ip);
    }
    return;
  }
  std::vector<int> goodIdFiltered;
  for (std::set<int>::const_iterator it = goodId.begin(); it != goodId.end(); it++) {
    if ((idToInfo[*it].services & requestedFlags) == requestedFlags)
      goodIdFiltered.push_back(*it);
  }

  if (!goodIdFiltered.size())
    return;

  if (max > goodIdFiltered.size() / 2)
    max = goodIdFiltered.size() / 2;
  if (max < 1)
    max = 1;

  set<int> ids;
  while (ids.size() < max) {
    ids.insert(goodIdFiltered[rand() % goodIdFiltered.size()]);
  }
  for (set<int>::const_iterator it = ids.begin(); it != ids.end(); it++) {
    CService &ip = idToInfo[*it].ip;
    if (nets[ip.GetNetwork()])
      ips.insert(ip);
  }
}
